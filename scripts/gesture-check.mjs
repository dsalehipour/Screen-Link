/**
 * Covers the phone behaviours that are easy to get subtly wrong and impossible to eyeball:
 * what a two-finger tap sends to the Mac, whether three taps turn control on, whether the bar
 * survives being zoomed under, and whether the resolution picker actually rescales the stream.
 *
 * The two-finger case is checked against the real cursor as well as the wire, because "we sent no
 * move" and "the pointer did not move" are different claims and only the second one is the bug.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Session, sleep } from './cdp.mjs';

const run = promisify(execFile);
const URL = process.argv[2] ?? 'http://127.0.0.1:8766/';
const TOKEN = process.argv[3] ?? '';

const cursor = async () => {
  const { stdout } = await run('./build/cursorprobe', []);
  return JSON.parse(stdout).cursor;
};

const session = await Session.attach();
await session.send('Emulation.setDeviceMetricsOverride', {
  width: 412, height: 915, deviceScaleFactor: 2.6, mobile: true,
});
await session.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

console.log('landed on:', await session.open(`${URL}#t=${TOKEN}`));
await sleep(1500);
for (let i = 0; i < 20; i++) {
  try {
    await run('osascript', ['-e',
      'tell application "System Events" to tell process "screenlink" to click button "Approve" of window 1']);
    break;
  } catch { await sleep(400); }
}
await sleep(4000);

// Everything the page puts on the wire, so a gesture can be judged by what the Mac would receive.
await session.evaluate(`(() => {
  window.__sent = [];
  const original = send;
  send = (msg) => { window.__sent.push(msg); return original(msg); };
})()`);

const sent = async (clear = true) => {
  const out = JSON.parse(await session.evaluate('JSON.stringify(window.__sent)'));
  if (clear) await session.evaluate('window.__sent = []');
  return out;
};

const touch = (x, y) => ({ x, y, radiusX: 12, radiusY: 12, force: 1 });
async function dispatch(type, points) {
  await session.send('Input.dispatchTouchEvent', { type, touchPoints: points });
  await sleep(20);
}

const state = async () => JSON.parse(await session.evaluate(`(() => {
  const canvas = document.querySelector('canvas');
  return JSON.stringify({
    controlling,
    scale: +view.scale.toFixed(2),
    size: canvas.width + 'x' + canvas.height,
    maxWidth: currentMaxWidth,
    quality: document.getElementById('quality').value,
    qualityOptions: [...document.getElementById('quality').options].map((o) => o.value),
    hintPresent: !!document.querySelector('.hint'),
    res: document.getElementById('res').textContent,
  });
})()`));

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

// ---- the read-only hint is gone ---------------------------------------------

check('the read-only hint is gone', (await state()).hintPresent === false);

// ---- three taps enable control ----------------------------------------------

await session.evaluate('resetView()');
await session.evaluate('if (controlling) document.getElementById("control").click()');
await sent();

async function tap(x, y) {
  await dispatch('touchStart', [touch(x, y)]);
  await dispatch('touchEnd', []);
}

await tap(206, 500);
await tap(206, 502);
const twoTaps = await state();
check('two taps do not enable control', twoTaps.controlling === false);

await tap(206, 501);
const threeTaps = await state();
check('three quick taps enable control', threeTaps.controlling === true);
check('the taps themselves reached nothing on the Mac',
  (await sent()).filter((m) => m.type === 'mouse').length === 0);

await session.evaluate('if (controlling) document.getElementById("control").click()');
await tap(206, 500);
await sleep(700);
await tap(206, 500);
await sleep(700);
await tap(206, 500);
check('slow taps do not enable control', (await state()).controlling === false);

// ---- a two-finger tap must not disturb the cursor ---------------------------

await session.evaluate('if (!controlling) document.getElementById("control").click()');
await sleep(200);
await sent();

// Park the pointer somewhere known, then let go of it entirely.
await tap(206, 500);
await sleep(500);
const parked = await cursor();
await sent();

// Both fingers land together, as they do when you mean to pinch.
await dispatch('touchStart', [touch(180, 460)]);
await session.send('Input.dispatchTouchEvent', {
  type: 'touchStart', touchPoints: [touch(180, 460), touch(240, 460)],
});
await sleep(120);
await dispatch('touchEnd', [touch(180, 460)]);
await dispatch('touchEnd', []);
await sleep(400);

const twoFingerTraffic = await sent();
const moved = await cursor();
check('a two-finger tap sends no pointer input',
  twoFingerTraffic.filter((m) => m.type === 'mouse').length === 0,
  `sent=${JSON.stringify(twoFingerTraffic.map((m) => m.type + '/' + (m.action ?? '')))}`);
check('a two-finger tap leaves the cursor where it was',
  Math.hypot(moved.x - parked.x, moved.y - parked.y) < 2,
  `${parked.x},${parked.y} -> ${moved.x},${moved.y}`);

// A single finger must still work, or the fix above traded one bug for another.
await sent();
await tap(250, 520);
await sleep(400);
const singleTraffic = await sent();
const afterSingle = await cursor();
check('a one-finger tap still clicks',
  singleTraffic.some((m) => m.type === 'mouse' && m.action === 'down')
  && singleTraffic.some((m) => m.type === 'mouse' && m.action === 'up'),
  `sent=${singleTraffic.map((m) => m.action ?? m.type).join(',')}`);
check('a one-finger tap moves the cursor before pressing',
  singleTraffic.findIndex((m) => m.action === 'move') === 0
  && Math.hypot(afterSingle.x - parked.x, afterSingle.y - parked.y) > 2,
  `cursor ${parked.x},${parked.y} -> ${afterSingle.x},${afterSingle.y}`);

// ---- the bar stays on top of the picture ------------------------------------

const pinch = async (centre, from, to, steps = 14) => {
  const at = (gap) => [touch(centre.x, centre.y - gap / 2), touch(centre.x, centre.y + gap / 2)];
  await dispatch('touchStart', at(from));
  for (let i = 1; i <= steps; i++) await dispatch('touchMove', at(from + ((to - from) * i) / steps));
  await dispatch('touchEnd', []);
};

await session.evaluate('resetView()');
for (let i = 0; i < 4; i++) await pinch({ x: 206, y: 460 }, 100, 700);
const deep = await state();
// The canvas box genuinely extends past the top of the screen once zoomed; what matters is that
// nothing of it is painted or clickable over the bar, which is a hit test, not a comparison of rects.
const overBar = JSON.parse(await session.evaluate(`(() => {
  const button = document.getElementById('control');
  const r = button.getBoundingClientRect();
  const header = document.querySelector('header').getBoundingClientRect();
  const across = [];
  for (let f = 0.05; f < 1; f += 0.1) {
    const hit = document.elementFromPoint(window.innerWidth * f, header.top + header.height / 2);
    across.push(hit ? (hit.id || hit.tagName) : null);
  }
  return JSON.stringify({
    hits: document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)?.id ?? null,
    across,
    canvasClipped: getComputedStyle(document.querySelector('main')).overflow === 'hidden',
  });
})()`));
check('the control button is still hittable when zoomed in',
  overBar.hits === 'control', `scale=${deep.scale} elementFromPoint=${overBar.hits}`);
check('no part of the zoomed picture sits over the bar',
  overBar.canvasClipped && !overBar.across.includes('CANVAS'),
  `across the bar: ${overBar.across.join(', ')}`);

// Turning control back off has to work through that button, since triple tap only turns it on.
await session.evaluate(`document.getElementById('control').click()`);
check('control can be turned off from the bar', (await state()).controlling === false);

// ---- resolution ---------------------------------------------------------------

const setQuality = async (width) => {
  await session.evaluate(`(() => {
    const select = document.getElementById('quality');
    select.value = '${width}';
    select.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await sleep(6000);
};

await session.evaluate('resetView()');
// From a known step, since the app keeps whatever the last run left it on.
await setQuality(1920);
const beforeQuality = await state();
check('the resolution picker offers more than one step',
  beforeQuality.qualityOptions.length > 1, `options=${beforeQuality.qualityOptions}`);

await setQuality(0);
const full = await state();
check('full resolution enlarges the stream',
  Number(full.size.split('x')[0]) > Number(beforeQuality.size.split('x')[0]),
  `${beforeQuality.size} -> ${full.size}`);
check('the server confirms the new scale', full.maxWidth === 0, `maxWidth=${full.maxWidth}`);

const framesAt = async () => Number(await session.evaluate('String(stats.frames)'));
await sleep(1200);
check('frames still arrive at full resolution', (await framesAt()) > 0, `fps sample=${await framesAt()}`);

await setQuality(1920);
const back = await state();
check('the stream comes back down again', back.maxWidth === 1920 && back.size !== full.size,
  `${full.size} -> ${back.size} maxWidth=${back.maxWidth}`);

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
session.ws.close();
process.exit(failed.length ? 1 : 0);
