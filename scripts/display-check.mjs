/**
 * Switches display from the browser and checks that the picture actually changes.
 *
 * The protocol side of this is easy to confirm and was never the problem; what matters is whether
 * the canvas ends up showing the other screen, which only a real decode can answer.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Session, sleep } from './cdp.mjs';

const run = promisify(execFile);
const URL = process.argv[2] ?? 'http://127.0.0.1:8766/';
const TOKEN = process.argv[3] ?? '';

async function approve() {
  for (let i = 0; i < 25; i++) {
    try {
      await run('osascript', ['-e',
        'tell application "System Events" to tell process "screenlink" to click button "Approve" of window 1']);
      return true;
    } catch { await sleep(400); }
  }
  return false;
}

const session = await Session.attach();
await session.send('Emulation.setDeviceMetricsOverride', {
  width: 412, height: 915, deviceScaleFactor: 2.6, mobile: true,
});
await session.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

console.log('landed on:', await session.open(`${URL}#t=${TOKEN}`));
await sleep(1500);
await approve();
await sleep(4000);

/** A cheap signature of what is on screen, plus the state the client believes it is in. */
const snapshot = () => session.evaluate(`(() => {
  const canvas = document.querySelector('canvas');
  const select = document.getElementById('display');
  const probe = document.createElement('canvas');
  probe.width = 32; probe.height = 32;
  probe.getContext('2d').drawImage(canvas, 0, 0, 32, 32);
  const pixels = probe.getContext('2d').getImageData(0, 0, 32, 32).data;
  let hash = 0;
  for (let i = 0; i < pixels.length; i += 4) hash = (hash * 31 + pixels[i]) >>> 0;
  return JSON.stringify({
    hash,
    size: canvas.width + 'x' + canvas.height,
    selected: select.value,
    options: [...select.options].map((o) => o.value),
    selectVisible: select.offsetWidth > 0 && getComputedStyle(select).display !== 'none',
    selectWidth: select.getBoundingClientRect().width,
    overlay: document.getElementById('overlay').classList.contains('hidden')
      ? null : document.getElementById('overlay').textContent,
  });
})()`);

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

const before = JSON.parse(await snapshot());
console.log('before:', before);
check('stream is running', before.overlay === null && before.size !== '300x150', `size=${before.size}`);
check('both displays are offered', before.options.length > 1, `options=${before.options}`);
check('the picker is reachable on a phone-sized screen', before.selectVisible && before.selectWidth > 40,
  `width=${before.selectWidth.toFixed(0)}px visible=${before.selectVisible}`);

const other = before.options.find((id) => id !== before.selected);
console.log(`switching ${before.selected} -> ${other}`);
await session.evaluate(`(() => {
  const select = document.getElementById('display');
  select.value = ${JSON.stringify(other)};
  select.dispatchEvent(new Event('change', { bubbles: true }));
})()`);

await sleep(6000);
const after = JSON.parse(await snapshot());
console.log('after:', after);

check('the client now reports the other display', after.selected === other,
  `selected=${after.selected} wanted=${other}`);
check('the canvas resized to the other display', after.size !== before.size,
  `${before.size} -> ${after.size}`);
check('the picture actually changed', after.hash !== before.hash,
  `hash ${before.hash} -> ${after.hash}`);
check('no overlay is stuck on screen', after.overlay === null, `overlay=${JSON.stringify(after.overlay)}`);

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
session.ws.close();
process.exit(failed.length ? 1 : 0);
