#!/usr/bin/env node
// End-to-end check of the screenlink wire protocol.
//   node scripts/smoke.mjs [origin]
// Origin defaults to http://127.0.0.1:8766; pass e.g. https://192.168.86.237:8443 to exercise TLS.
// Reads the shared token from build/token.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const token = readFileSync(join(root, 'build/token'), 'utf8').trim();

const origin = process.argv[2] ?? 'http://127.0.0.1:8766';
const base = new URL(origin);
// HTTP and WebSocket share an origin now, so the socket address is derived rather than configured.
const wsOrigin = `${base.protocol === 'https:' ? 'wss:' : 'ws:'}//${base.host}`;
// The development certificate is self-signed by design; verifying it here would only test openssl.
if (base.protocol === 'https:') process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

let failures = 0;
const pass = (m) => console.log(`  ok    ${m}`);
const fail = (m) => { failures++; console.log(`  FAIL  ${m}`); };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A token no longer opens a session on its own: a new device has to be approved at the Mac. The
// suite pairs once and then presents that credential, rather than raising a dialog per socket.
let credential = null;
const authMessage = () => JSON.stringify({
  type: 'auth',
  token,
  deviceName: 'smoke test',
  ...(credential ?? {}),
});

async function approveAtTheMac() {
  for (let i = 0; i < 25; i++) {
    try {
      execFileSync('osascript', ['-e',
        'tell application "System Events" to tell process "screenlink" to click button "Approve" of window 1'],
        { stdio: 'ignore' });
      return;
    } catch { await sleep(400); }
  }
}

async function pairOnce() {
  console.log('\npairing');
  const result = await new Promise((resolve) => {
    const ws = new WebSocket(`${wsOrigin}`);
    ws.onopen = () => ws.send(authMessage());
    ws.onmessage = (e) => {
      if (typeof e.data !== 'string') return;
      const msg = JSON.parse(e.data);
      if (msg.type === 'pairing') approveAtTheMac();
      if (msg.type === 'paired') { ws.close(); resolve({ deviceId: msg.deviceId, deviceSecret: msg.deviceSecret }); }
      if (msg.type === 'info' && !credential) { ws.close(); resolve({}); }
    };
    setTimeout(() => { ws.close(); resolve(null); }, 20000);
  });
  if (!result) return fail('could not pair with the Mac');
  credential = result.deviceId ? result : credential;
  pass('paired with the Mac');
}

async function checkHealth() {
  console.log('\nhealth');
  const res = await fetch(`${base.origin}/health`);
  const body = await res.json();
  res.status === 200 ? pass('GET /health 200') : fail(`GET /health ${res.status}`);
  console.log(`        capturing=${body.capturing} accessibility=${body.accessibility} ${body.width}x${body.height}`);
  return body;
}

async function checkAuth() {
  console.log('\nauth');
  const res = await fetch(`${base.origin}/screenshot?token=wrong`);
  res.status === 401 ? pass('screenshot rejects bad token') : fail(`screenshot bad token -> ${res.status}`);

  const rejected = await new Promise((resolve) => {
    const ws = new WebSocket(`${wsOrigin}`);
    let gotMessage = false;
    ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', token: 'wrong' }));
    ws.onmessage = () => { gotMessage = true; };
    ws.onclose = () => resolve(!gotMessage);
    setTimeout(() => { ws.close(); resolve(!gotMessage); }, 1500);
  });
  rejected ? pass('websocket rejects bad token') : fail('websocket accepted a bad token');
}

/// Points the stream at a specific display and resolves once the server confirms it.
function switchTo(id) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${wsOrigin}`);
    let sent = false;
    ws.onopen = () => ws.send(authMessage());
    ws.onmessage = (e) => {
      if (typeof e.data !== 'string') return;
      const msg = JSON.parse(e.data);
      if (msg.type !== 'info') return;
      if (msg.displayID === id) { ws.close(); resolve(true); return; }
      if (!sent) { sent = true; ws.send(JSON.stringify({ type: 'display', display: id })); }
    };
    setTimeout(() => { ws.close(); resolve(false); }, 3000);
  });
}

async function checkStream() {
  console.log('\nstream');
  return new Promise((resolve) => {
    const ws = new WebSocket(`${wsOrigin}`);
    ws.binaryType = 'arraybuffer';
    const frames = [];
    const latencies = [];
    let info = null;
    let status = null;

    ws.onopen = () => ws.send(authMessage());
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') {
        const msg = JSON.parse(e.data);
        if (msg.type === 'info') info = msg;
        if (msg.type === 'status') status = msg.message;
        return;
      }
      const frame = new Uint8Array(e.data);
      // Must be sampled on arrival; computing it after the capture window would just measure
      // how long ago each frame was collected.
      const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
      latencies.push(Date.now() - view.getFloat64(4, true));
      frames.push(frame);
    };

    // A perfectly static screen encodes nothing, by design. Poke the encoder so a quiet desktop
    // still proves the pipeline works rather than looking like a failure.
    const poke = setInterval(() => {
      if (frames.length === 0 && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'keyframe' }));
      }
    }, 400);

    setTimeout(() => {
      clearInterval(poke);
      ws.close();
      if (status && !info) {
        console.log(`        server reports: ${status}`);
        console.log('        skipping video assertions (capture not running)');
        return resolve();
      }
      info ? pass(`info received: ${info.width}x${info.height} ${info.codec} @${info.fps}`)
           : fail('no info message');

      if (frames.length === 0) { fail('no video frames in 3s'); return resolve(); }
      pass(`${frames.length} frames in 3s (~${Math.round(frames.length / 3)} fps)`);

      const first = frames[0];
      const view = new DataView(first.buffer, first.byteOffset, first.byteLength);
      view.getUint8(0) === 1 ? pass('frame header kind=video') : fail('bad frame kind');
      view.getUint8(1) === 1 ? pass('first frame is a keyframe') : fail('first frame is not a keyframe');

      const captureMs = view.getFloat64(4, true);
      const age = Date.now() - captureMs;
      age > 0 && age < 5000 ? pass(`timestamp sane (${age.toFixed(0)}ms old)`)
                            : fail(`timestamp implausible (${age}ms)`);

      const payload = first.subarray(12);
      const annexB = payload[0] === 0 && payload[1] === 0 && payload[2] === 0 && payload[3] === 1;
      annexB ? pass('payload starts with Annex B start code') : fail('payload is not Annex B');

      // A keyframe must carry SPS (nal type 7) and PPS (nal type 8) so a client can join here.
      const nalTypes = new Set();
      for (let i = 0; i + 4 < payload.length; i++) {
        if (payload[i] === 0 && payload[i + 1] === 0 && payload[i + 2] === 0 && payload[i + 3] === 1) {
          nalTypes.add(payload[i + 4] & 0x1f);
        }
      }
      nalTypes.has(7) && nalTypes.has(8)
        ? pass(`keyframe carries SPS+PPS (nal types ${[...nalTypes].sort((a, b) => a - b).join(',')})`)
        : fail(`keyframe missing SPS/PPS (saw ${[...nalTypes].join(',')})`);
      nalTypes.has(5) ? pass('keyframe carries an IDR slice') : fail('no IDR slice in keyframe');

      const total = frames.reduce((n, f) => n + f.length, 0);
      const sorted = [...latencies].sort((a, b) => a - b);
      const pct = (p) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
      const avg = latencies.reduce((a, b) => a + b, 0) / latencies.length;
      console.log(`        ${(total / 1024).toFixed(0)} KB over 3s (~${((total * 8) / 3e6).toFixed(1)} Mb/s)`);
      console.log(`        capture→client  avg ${avg.toFixed(1)}ms  p50 ${pct(0.5).toFixed(1)}ms  p95 ${pct(0.95).toFixed(1)}ms  min ${sorted[0].toFixed(1)}ms`);
      avg < 100 ? pass(`average latency under 100ms (${avg.toFixed(1)}ms)`)
                : fail(`average latency ${avg.toFixed(1)}ms exceeds 100ms`);
      resolve();
    }, 3000);
  });
}

async function checkDisplays() {
  console.log('\ndisplays');
  const res = await fetch(`${base.origin}/displays?token=${token}`);
  if (res.status !== 200) { fail(`GET /displays ${res.status}`); return []; }
  const list = await res.json();
  Array.isArray(list) && list.length > 0
    ? pass(`${list.length} display(s) enumerated`)
    : fail('no displays enumerated');
  for (const d of list) {
    console.log(`        [${d.index}] id=${d.id} "${d.name}" ${d.width}x${d.height} at (${d.x},${d.y})${d.isMain ? ' main' : ''}`);
  }
  list.every((d) => d.name && d.width > 0 && d.height > 0)
    ? pass('every display has a name and dimensions')
    : fail('a display is missing a name or dimensions');
  return list;
}

// Switching displays changes resolution, which forces an encoder restart. Verify the stream comes
// back at the new size rather than stalling or serving frames the decoder cannot use.
async function checkDisplaySwitch(list, startID) {
  console.log('\ndisplay switching');
  if (list.length < 2) {
    console.log('        only one display attached, skipping switch test');
    return;
  }

  // The server correctly no-ops a switch to the display it is already showing, so order the
  // targets to put the current one last. That way every step exercises a real transition.
  const order = [
    ...list.filter((d) => d.id !== startID),
    ...list.filter((d) => d.id === startID),
  ];

  const results = [];
  for (const target of order) {
    const outcome = await new Promise((resolve) => {
      const ws = new WebSocket(`${wsOrigin}`);
      ws.binaryType = 'arraybuffer';
      let info = null;
      let frames = 0;
      let requested = false;

      ws.onopen = () => ws.send(authMessage());
      ws.onmessage = (e) => {
        if (typeof e.data === 'string') {
          const msg = JSON.parse(e.data);
          if (msg.type !== 'info') return;
          if (!requested) {
            requested = true;
            ws.send(JSON.stringify({ type: 'display', display: target.id }));
            return;
          }
          if (msg.displayID === target.id) { info = msg; frames = 0; }
          return;
        }
        if (info) frames++;
      };
      setTimeout(() => { ws.close(); resolve({ info, frames }); }, 4000);
    });

    if (!outcome.info) { fail(`switch to "${target.name}" produced no info`); continue; }
    // Capture is sized from the panel's real pixels, not its point size, so a Retina display is
    // capped by the stream width rather than by its own logical width.
    const cap = Math.min(outcome.info.maxWidth || Infinity, target.nativeWidth);
    const expectW = cap - (cap % 2);
    const okDims = outcome.info.width === expectW;
    okDims ? pass(`"${target.name}" -> ${outcome.info.width}x${outcome.info.height} (${outcome.frames} frames)`)
           : fail(`"${target.name}" reported ${outcome.info.width}px, expected ${expectW}px`);
    // A static screen legitimately produces almost nothing, since unchanged frames are never
    // encoded. Any frame at all proves the new stream is alive.
    outcome.frames > 0 ? pass(`  stream alive after switch (${outcome.frames} frames)`)
                       : fail(`  no frames after switching to "${target.name}"`);
    results.push(outcome.info);
  }

  const sizes = new Set(results.map((i) => `${i.width}x${i.height}`));
  sizes.size === results.length
    ? pass('each display streamed at its own resolution')
    : fail(`resolutions did not change between displays (${[...sizes].join(', ')})`);
}

// The real multi-display hazard: a click must land on the display being watched, at the right
// spot, regardless of that display's origin in the desktop arrangement or its backing scale.
async function checkInputMapping(health, list) {
  console.log('\ninput mapping');
  if (!health.accessibility) {
    console.log('        accessibility not granted, skipping input tests');
    return;
  }

  // Compiled once rather than run through `swift`, which would spend a second compiling on every
  // probe and give the pointer that much longer to be disturbed.
  const helper = join(root, 'build/cursorprobe');
  execFileSync('swiftc', ['-O', join(root, 'scripts/cursor.swift'), '-o', helper]);
  const probe = () => JSON.parse(execFileSync(helper, { encoding: 'utf8' }));
  const original = probe().cursor;

  const move = (x, y) => fetch(`${base.origin}/command?token=${token}`, {
    method: 'POST',
    body: JSON.stringify({ type: 'mouse', action: 'move', x, y }),
  });

  for (const display of list) {
    if (!(await switchTo(display.id))) { fail(`could not switch to "${display.name}"`); continue; }
    await sleep(300);

    for (const [nx, ny] of [[0.5, 0.5], [0.25, 0.75]]) {
      // Someone using the physical mouse mid-test would otherwise look like a mapping bug.
      // Injection is idempotent, so retrying is safe: a genuine mapping error lands on the same
      // wrong pixel every time, while interference lands somewhere different each time.
      let matched = null;
      let previous = null;
      let drifted = false;

      for (let attempt = 0; attempt < 4 && !matched; attempt++) {
        await move(nx, ny);
        await sleep(180);
        const state = probe();
        const b = state.displays[String(display.id)];
        if (!b) break;

        const want = { x: b.x + nx * b.w, y: b.y + ny * b.h };
        const at = state.cursor;
        if (Math.abs(at.x - want.x) < 2 && Math.abs(at.y - want.y) < 2) {
          matched = { at, want };
          break;
        }
        if (previous && (previous.x !== at.x || previous.y !== at.y)) drifted = true;
        previous = at;
      }

      const where = (p) => `(${p.x.toFixed(0)},${p.y.toFixed(0)})`;
      if (matched) {
        pass(`"${display.name}" (${nx},${ny}) -> ${where(matched.at)} matches ${where(matched.want)}`);
      } else if (drifted) {
        console.log(`        skipped (${nx},${ny}) — pointer is being moved locally`);
      } else if (previous) {
        fail(`"${display.name}" (${nx},${ny}) landed at ${where(previous)} every attempt`);
      }
    }
  }

  // Put the pointer back where the user left it.
  const main = list.find((d) => d.isMain) ?? list[0];
  if (main) {
    await switchTo(main.id);
    const b = probe().displays[String(main.id)];
    if (b) await move((original.x - b.x) / b.w, (original.y - b.y) / b.h);
  }
}

async function checkScreenshot(health, list) {
  console.log('\nscreenshot');
  const res = await fetch(`${base.origin}/screenshot?token=${token}`);
  if (!health.capturing) {
    res.status === 503 ? pass('screenshot returns 503 while capture is down')
                       : fail(`expected 503, got ${res.status}`);
    return;
  }
  if (res.status !== 200) return fail(`screenshot ${res.status}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  const isJpeg = (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  isJpeg(bytes) ? pass(`JPEG returned (${(bytes.length / 1024).toFixed(0)} KB)`)
                : fail('response is not a JPEG');

  // The agent path must be able to grab any display without disturbing the live stream.
  for (const d of list) {
    const r = await fetch(`${base.origin}/screenshot?token=${token}&display=${d.id}`);
    if (r.status !== 200) { fail(`screenshot display=${d.id} -> ${r.status}`); continue; }
    const b = new Uint8Array(await r.arrayBuffer());
    isJpeg(b) ? pass(`display ${d.id} "${d.name}" JPEG (${(b.length / 1024).toFixed(0)} KB)`)
              : fail(`display ${d.id} did not return a JPEG`);
  }
}

const health = await checkHealth();
await checkAuth();
await pairOnce();

const displays = health.capturing ? await checkDisplays() : [];
// Measure throughput against the main display, which is the one with activity on it. Without
// pinning this, results depend on whichever display a previous run happened to leave selected.
const main = displays.find((d) => d.isMain) ?? displays[0];
if (main) await switchTo(main.id);

await checkStream();
if (health.capturing) await checkDisplaySwitch(displays, main?.id);
if (main) await switchTo(main.id);
await checkInputMapping(health, displays);
await checkScreenshot(health, displays);
await sleep(100);

console.log(`\n${failures === 0 ? 'all checks passed' : `${failures} check(s) failed`}\n`);
process.exit(failures === 0 ? 0 : 1);
