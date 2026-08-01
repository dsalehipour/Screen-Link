/**
 * Exercises the phone view transform through real touch events on an emulated handset.
 *
 * Two things are being pinned down: a single finger pans while control is off, and no part of the
 * remote screen becomes unreachable once zoomed in.
 *
 * Note that the control-mode section drives the Mac for real, moving the pointer and pressing the
 * left button. Run it when the desktop underneath can tolerate a stray drag.
 */
import { Session, sleep } from './cdp.mjs';

const URL = process.argv[2] ?? 'https://192.168.86.237:8443/';

const session = await Session.attach();

// A tall narrow handset is the case that letterboxes a wide Mac display, which is where the view
// maths has the most room to be wrong.
await session.send('Emulation.setDeviceMetricsOverride', {
  width: 412, height: 915, deviceScaleFactor: 2.6, mobile: true,
});
await session.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

console.log('landed on:', await session.open(URL));
await sleep(3000);

const touch = (x, y) => ({ x, y, radiusX: 12, radiusY: 12, force: 1 });

async function dispatch(type, points) {
  await session.send('Input.dispatchTouchEvent', { type, touchPoints: points });
  await sleep(20);
}

/** Drags one finger from a point by a delta, in steps, as a real swipe would arrive. */
async function drag(from, dx, dy, steps = 10) {
  await dispatch('touchStart', [touch(from.x, from.y)]);
  for (let i = 1; i <= steps; i++) {
    await dispatch('touchMove', [touch(from.x + (dx * i) / steps, from.y + (dy * i) / steps)]);
  }
  await dispatch('touchEnd', []);
}

/** Spreads two fingers apart about a point. */
async function pinchOut(centre, from, to, steps = 14) {
  const at = (gap) => [
    touch(centre.x, centre.y - gap / 2),
    touch(centre.x, centre.y + gap / 2),
  ];
  await dispatch('touchStart', at(from));
  for (let i = 1; i <= steps; i++) {
    await dispatch('touchMove', at(from + ((to - from) * i) / steps));
  }
  await dispatch('touchEnd', []);
}

const geometry = async () => JSON.parse(await session.evaluate(`(() => {
  const canvas = document.querySelector('canvas');
  const s = canvas.parentElement.getBoundingClientRect();
  const c = canvas.getBoundingClientRect();
  const box = (r) => ({ left: +r.left.toFixed(2), right: +r.right.toFixed(2),
                        top: +r.top.toFixed(2), bottom: +r.bottom.toFixed(2),
                        w: +r.width.toFixed(2), h: +r.height.toFixed(2) });
  return JSON.stringify({
    scale: +view.scale.toFixed(3), x: +view.x.toFixed(1), y: +view.y.toFixed(1),
    controlling,
    canvas: box(c), stage: box(s),
    bodyFillsViewport: Math.abs(document.body.clientHeight - window.innerHeight) < 1,
  });
})()`));

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

/** Drags repeatedly in one direction until the view stops moving, then reports where it settled. */
async function panToLimit(dx, dy) {
  let previous = await geometry();
  for (let i = 0; i < 14; i++) {
    await drag({ x: 206, y: 460 }, dx, dy);
    const now = await geometry();
    if (Math.abs(now.x - previous.x) < 0.5 && Math.abs(now.y - previous.y) < 0.5) break;
    previous = now;
  }
  return geometry();
}

/**
 * Nothing may be stranded off screen. Along an axis the image either covers the stage, in which
 * case the far edge must be reachable, or it is smaller and must sit entirely inside.
 */
function edgeReport(g, axis) {
  const [near, far, size] = axis === 'x'
    ? ['left', 'right', 'w']
    : ['top', 'bottom', 'h'];
  const covers = g.canvas[size] > g.stage[size] + 1;
  return { covers, near: g.canvas[near] - g.stage[near], far: g.canvas[far] - g.stage[far] };
}

const start = await geometry();
check('starts in read-only mode', start.controlling === false, `controlling=${start.controlling}`);
check('body fills the visible viewport', start.bodyFillsViewport);

await session.evaluate('resetView()');
await pinchOut({ x: 206, y: 460 }, 120, 620);
const zoomed = await geometry();
check('pinch zooms in', zoomed.scale > 1.5, `scale=${zoomed.scale}`);
check('zoom leaves no gap at the sides', zoomed.canvas.w > zoomed.stage.w,
  `canvas ${zoomed.canvas.w} vs stage ${zoomed.stage.w}`);

// One finger, control off, along the axis that actually has slack on this geometry.
const before = await geometry();
await drag({ x: 320, y: 460 }, -200, 0);
const after = await geometry();
check('one finger pans while control is off', Math.abs(after.x - before.x) > 20,
  `view.x ${before.x} -> ${after.x}`);

const right = await panToLimit(-320, -320);
const rx = edgeReport(right, 'x');
const ry = edgeReport(right, 'y');
check('far edge reachable horizontally', rx.covers ? Math.abs(rx.far) < 1.5 : rx.far <= 1.5,
  `canvas.right - stage.right = ${rx.far.toFixed(2)}`);
check('nothing stranded below the fold', ry.covers ? Math.abs(ry.far) < 1.5 : ry.far <= 1.5,
  `canvas.bottom - stage.bottom = ${ry.far.toFixed(2)} (covers=${ry.covers})`);

const left = await panToLimit(320, 320);
const lx = edgeReport(left, 'x');
const ly = edgeReport(left, 'y');
check('near edge reachable horizontally', lx.covers ? Math.abs(lx.near) < 1.5 : lx.near >= -1.5,
  `canvas.left - stage.left = ${lx.near.toFixed(2)}`);
check('nothing stranded above the fold', ly.covers ? Math.abs(ly.near) < 1.5 : ly.near >= -1.5,
  `canvas.top - stage.top = ${ly.near.toFixed(2)} (covers=${ly.covers})`);

// Zoom far enough that the image is taller than the screen. This is the case behind the original
// report: with a wide Mac display on a tall phone, vertical panning only has anything to do once
// the zoom is deep enough for the strip to outgrow the viewport.
await session.evaluate('resetView()');
for (let i = 0; i < 4; i++) await pinchOut({ x: 206, y: 460 }, 100, 700);
const deep = await geometry();
check('zooms deep enough to overflow vertically', deep.canvas.h > deep.stage.h,
  `canvas ${deep.canvas.h} vs stage ${deep.stage.h} at scale ${deep.scale}`);

if (deep.canvas.h > deep.stage.h) {
  const down = edgeReport(await panToLimit(0, -400), 'y');
  check('bottom edge reachable when zoomed in',
    Math.abs(down.far) < 1.5, `canvas.bottom - stage.bottom = ${down.far.toFixed(2)}`);
  const up = edgeReport(await panToLimit(0, 400), 'y');
  check('top edge reachable when zoomed in',
    Math.abs(up.near) < 1.5, `canvas.top - stage.top = ${up.near.toFixed(2)}`);
}

// With control on, a single finger belongs to the Mac again. Two fingers still move the view.
await session.evaluate('resetView()');
await pinchOut({ x: 206, y: 460 }, 120, 620);
await session.evaluate(`if (!controlling) document.getElementById('control').click()`);
const controlOn = await geometry();
check('control mode engages', controlOn.controlling === true);

const beforeControlDrag = await geometry();
await drag({ x: 320, y: 460 }, -200, 0);
const afterControlDrag = await geometry();
check('one finger does not pan while controlling',
  Math.abs(afterControlDrag.x - beforeControlDrag.x) < 1,
  `view.x ${beforeControlDrag.x} -> ${afterControlDrag.x}`);

await dispatch('touchStart', [touch(300, 440), touch(300, 500)]);
for (let i = 1; i <= 8; i++) {
  await dispatch('touchMove', [touch(300 - i * 12, 440), touch(300 - i * 12, 500)]);
}
await dispatch('touchEnd', []);
const afterTwoFinger = await geometry();
check('two fingers still pan while controlling',
  Math.abs(afterTwoFinger.x - afterControlDrag.x) > 20,
  `view.x ${afterControlDrag.x} -> ${afterTwoFinger.x}`);

await session.evaluate(`if (controlling) document.getElementById('control').click()`);
await session.evaluate('resetView()');
const reset = await geometry();
check('reset returns to fit', reset.scale === 1 && Math.abs(reset.canvas.h - reset.stage.h) < 1
  ? true
  : reset.scale === 1 && reset.canvas.h <= reset.stage.h + 1,
  `scale=${reset.scale}`);

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
session.ws.close();
process.exit(failed.length ? 1 : 0);
