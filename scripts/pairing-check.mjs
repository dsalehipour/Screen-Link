/**
 * Checks that holding the link is not the same as having access.
 *
 * The property being defended: a token that leaked, was photographed, or was phished by something
 * impersonating this Mac still cannot open a session. Only a decision made at the Mac can, and only
 * until it is revoked.
 *
 * Drives the real approval dialog through the accessibility API, so what is exercised is the same
 * path a person uses rather than a test-only shortcut.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const ORIGIN = process.argv[2] ?? 'ws://127.0.0.1:8766';
const TOKEN = process.argv[3];

if (!TOKEN) {
  console.error('usage: pairing-check.mjs <ws-origin> <token>');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Clicks a button in screenlink's approval dialog, waiting for it to appear first. */
async function clickAlert(button) {
  for (let i = 0; i < 30; i++) {
    try {
      await run('osascript', ['-e',
        `tell application "System Events" to tell process "screenlink" to click button "${button}" of window 1`]);
      return true;
    } catch {
      await sleep(300);
    }
  }
  throw new Error(`approval dialog never offered a ${button} button`);
}

/**
 * Opens a session and collects what the server says back.
 * Resolves once the socket closes or the window elapses, whichever comes first.
 */
function attempt(auth, { windowMs = 4000, onPairing } = {}) {
  return new Promise((resolve) => {
    const seen = { messages: [], frames: 0, closed: false, pairing: null, credential: null };
    const ws = new WebSocket(ORIGIN);
    const finish = () => { try { ws.close(); } catch {} resolve(seen); };
    const timer = setTimeout(finish, windowMs);

    ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', deviceName: 'Chrome on Android', ...auth }));
    ws.onmessage = (event) => {
      if (typeof event.data !== 'string') { seen.frames++; return; }
      const msg = JSON.parse(event.data);
      seen.messages.push(msg.type);
      if (msg.type === 'pairing') {
        seen.pairing = msg.code;
        // Answered straight away. A prompt left sitting on screen is one that whoever is at the
        // Mac will answer instead, which makes the run depend on them.
        onPairing?.();
      }
      if (msg.type === 'paired') seen.credential = { id: msg.deviceId, secret: msg.deviceSecret };
    };
    ws.onclose = () => { seen.closed = true; clearTimeout(timer); resolve(seen); };
    ws.onerror = () => {};
  });
}

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

// A wrong token must not even be told whether pairing exists.
const wrong = await attempt({ token: 'f'.repeat(32) }, { windowMs: 2500 });
check('wrong token is refused', wrong.closed && wrong.messages.length === 0,
  `closed=${wrong.closed} messages=[${wrong.messages}]`);

const none = await attempt({}, { windowMs: 2500 });
check('missing token is refused', none.closed && none.messages.length === 0,
  `closed=${none.closed} messages=[${none.messages}]`);

// An unknown credential must fall back to asking, not be treated as valid.
const forged = await attempt(
  { token: TOKEN, deviceId: 'a'.repeat(16), deviceSecret: 'b'.repeat(64) },
  { windowMs: 12000, onPairing: () => clickAlert('Deny') });
check('forged credential does not grant a session',
  forged.pairing !== null && !forged.messages.includes('info'),
  `messages=[${forged.messages}]`);

// The heart of it: a valid token alone gets a request for approval and nothing else.
const denied = await attempt({ token: TOKEN },
  { windowMs: 12000, onPairing: () => clickAlert('Deny') });
check('valid token alone does not stream', !denied.messages.includes('info') && denied.frames === 0,
  `messages=[${denied.messages}] frames=${denied.frames}`);
check('pairing code is six digits', /^\d{6}$/.test(denied.pairing ?? ''), `code=${denied.pairing}`);
check('denial is reported and the socket ends',
  denied.messages.includes('denied') && denied.closed);

// Approving hands back a credential and opens the stream.
const approved = await attempt({ token: TOKEN },
  { windowMs: 15000, onPairing: () => clickAlert('Approve') });
check('approval grants a session', approved.messages.includes('info'), `messages=[${approved.messages}]`);
check('approval returns a credential',
  (approved.credential?.secret?.length ?? 0) === 64 && (approved.credential?.id?.length ?? 0) === 16,
  `id=${approved.credential?.id}`);
check('frames flow once approved', approved.frames > 0, `frames=${approved.frames}`);

// And that credential alone is enough next time: no token, no second approval.
const returning = await attempt({ ...approved.credential ? {
  deviceId: approved.credential.id, deviceSecret: approved.credential.secret,
} : {} }, { windowMs: 6000 });
check('approved device returns without the token',
  returning.messages.includes('info') && !returning.messages.includes('pairing'),
  `messages=[${returning.messages}]`);
check('returning device streams', returning.frames > 0, `frames=${returning.frames}`);

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
