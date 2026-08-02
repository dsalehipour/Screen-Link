/**
 * Types on a phone keyboard and checks what the client would send.
 *
 * A phone keyboard does not emit key presses. It composes: as a word is typed the IME revises a
 * pending string, and autocorrect can rewrite the whole thing before it settles. That is why this
 * drives `Input.imeSetComposition` rather than dispatching key events — key events would test a
 * path no phone actually takes, and would have passed while real typing was broken.
 *
 * Unlike the other checks here, this one does not drive the Mac. Typing is intercepted in the page
 * and replayed into the text it would have produced. Delivering it would type these words into
 * whichever app has the keyboard, and press Return on them — which is exactly what happened once.
 */
import { Session, sleep } from './cdp.mjs';
import { approveFromPage } from './approve.mjs';

const URL = process.argv[2] ?? 'http://127.0.0.1:8766/';
const TOKEN = process.argv[3] ?? '';

const session = await Session.attach();
await session.send('Emulation.setDeviceMetricsOverride', {
  width: 412, height: 915, deviceScaleFactor: 2.6, mobile: true,
});
await session.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

console.log('landed on:', await session.open(`${URL}#t=${TOKEN}`));
await sleep(1500);
await approveFromPage(session);
await sleep(3500);

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

// Typing is recorded, not delivered. Keystrokes land wherever macOS has the keyboard pointed, so a
// live connection would type this file's test words into whatever the author is looking at — and
// the Enter check would press Return on them. Everything else still goes through, since the session
// has to stay up for the client to behave normally.
await session.evaluate(`(() => {
  window.__sent = [];
  const original = send;
  send = (msg) => {
    window.__sent.push(msg);
    if (msg.type === 'text' || msg.type === 'key') return;
    return original(msg);
  };

  // Watched one layer down as well, at the socket. If the interception above is ever bypassed —
  // a handler that closes over the original, say — this is what notices, rather than the author
  // finding out from what appeared in their editor.
  window.__escaped = [];
  const realSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function (data) {
    try {
      const parsed = JSON.parse(data);
      if (parsed.type === 'text' || parsed.type === 'key') window.__escaped.push(parsed);
    } catch (_) {}
    return realSend.call(this, data);
  };
})()`);

const sent = async () => {
  const out = JSON.parse(await session.evaluate('JSON.stringify(window.__sent)'));
  await session.evaluate('window.__sent = []');
  return out;
};

/** What the Mac would end up with, replaying the protocol the way the injector does. */
function replay(messages) {
  let text = '';
  for (const m of messages) {
    if (m.type === 'text') text += m.text;
    if (m.type === 'key' && m.action === 'down' && m.code === 'Backspace') text = text.slice(0, -1);
  }
  return text;
}

// The keyboard button also turns control on, since typing into a read-only view looks broken.
await session.evaluate(`document.getElementById('keyboard').click()`);
await sleep(600);
const focused = await session.evaluate(
  `String(document.activeElement === document.getElementById('keyboard-sink')) + ' ' + controlling`);
check('the keyboard button focuses the field and enables control', focused === 'true true', focused);
await sent();

/** Types a word the way an IME does: a growing composition, then a commit. */
async function compose(word, { commitAs = word } = {}) {
  for (let i = 1; i <= word.length; i++) {
    await session.send('Input.imeSetComposition', {
      text: word.slice(0, i), selectionStart: i, selectionEnd: i,
    });
    await sleep(60);
  }
  await session.send('Input.insertText', { text: commitAs });
  await sleep(200);
}

await compose('hello');
const helloTraffic = await sent();
check('a composed word arrives in full', replay(helloTraffic) === 'hello',
  `reconstructed ${JSON.stringify(replay(helloTraffic))}`);

// The original failure: only the first characters landed, because composition was ignored.
await compose('there');
const secondWord = await sent();
check('a second word still arrives', replay(secondWord) === 'there',
  `reconstructed ${JSON.stringify(replay(secondWord))}`);

// Autocorrect settling on a different word than was typed.
await compose('helo', { commitAs: 'hello' });
const corrected = await sent();
check('autocorrect is sent as a correction, not a duplicate', replay(corrected) === 'hello',
  `reconstructed ${JSON.stringify(replay(corrected))} from ${corrected.length} messages`);

// Backspace against an empty field produces no event at all on Android without the padding.
await session.send('Input.dispatchKeyEvent', {
  type: 'keyDown', key: 'Backspace', code: 'Backspace',
  windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8,
});
await session.send('Input.dispatchKeyEvent', {
  type: 'keyUp', key: 'Backspace', code: 'Backspace',
  windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8,
});
await sleep(300);
const backspace = await sent();
check('backspace is sent even on an empty field',
  backspace.some((m) => m.type === 'key' && m.code === 'Backspace' && m.action === 'down'),
  `sent ${JSON.stringify(backspace.map((m) => m.code ?? m.text))}`);

for (const key of ['Enter', 'ArrowLeft', 'Tab']) {
  await session.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code: key });
  await session.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key });
  await sleep(150);
  const traffic = await sent();
  check(`${key} is forwarded once`,
    traffic.filter((m) => m.type === 'key' && m.code === key && m.action === 'down').length === 1,
    `sent ${JSON.stringify(traffic.map((m) => `${m.code}/${m.action}`))}`);
}

// ---- keeping the keyboard attached -----------------------------------------

// Aiming at a field on the Mac means tapping the picture, which can take focus off the hidden field
// the keyboard feeds. The keyboard stays up, so it looks fine, and nothing typed into it arrives.
await session.evaluate(`document.getElementById('keyboard-sink').blur()`);
const rect = JSON.parse(await session.evaluate(
  `JSON.stringify(document.getElementById('screen').getBoundingClientRect())`));
const spot = { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
for (const type of ['touchStart', 'touchEnd']) {
  await session.send('Input.dispatchTouchEvent', {
    type, touchPoints: type === 'touchEnd' ? [] : [{ x: spot.x, y: spot.y }],
  });
}
await sleep(500);
const refocused = await session.evaluate(
  `String(document.activeElement === document.getElementById('keyboard-sink'))`);
check('tapping the picture does not quietly detach the keyboard', refocused === 'true',
  `focused=${refocused}`);
await sent();

// ---- a keyboard that never announces composition ---------------------------

// Gboard does not reliably fire compositionstart/end; it reports a word in flight through the
// inputType alone. Code that trusts the composition events rewrites the field mid-word, the IME
// loses its place, and typing dies after a character or two — the reported bug. There is no way to
// provoke that through CDP, so the events are raised directly.
await session.evaluate(`(() => {
  const sink = document.getElementById('keyboard-sink');
  window.__rewrites = 0;
  window.__before = sink.value.length;
  const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  Object.defineProperty(sink, 'value', {
    get() { return descriptor.get.call(this); },
    set(v) { window.__rewrites++; return descriptor.set.call(this, v); },
    configurable: true,
  });
})()`);

await session.evaluate(`(async () => {
  const sink = document.getElementById('keyboard-sink');
  for (const ch of 'world') {
    sink.value = sink.value + ch;
    window.__rewrites--;  // the harness's own append is not the client rewriting the field
    sink.dispatchEvent(new InputEvent('input', { inputType: 'insertCompositionText', data: ch }));
    await new Promise((r) => setTimeout(r, 40));
  }
})()`);
await sleep(700);

const silent = replay(await sent());
const rewrites = Number(await session.evaluate('window.__rewrites'));
check('a keyboard that never announces composition still types', silent === 'world',
  `reconstructed ${JSON.stringify(silent)}`);
check('the field is not rewritten under the IME while a word is in flight', rewrites === 0,
  `the client rewrote it ${rewrites} times`);

// ---- a whole sentence ------------------------------------------------------

// The reported failure was that typing worked briefly and then stopped, so one word proves little.
const PHRASE = 'the quick brown fox';
for (const word of PHRASE.split(' ')) {
  await compose(word);
  await session.send('Input.insertText', { text: ' ' });
  await sleep(150);
}
const sentence = replay(await sent());
const escaped = JSON.parse(await session.evaluate('JSON.stringify(window.__escaped)'));
check('nothing was typed into the Mac', escaped.length === 0,
  escaped.length ? `${escaped.length} messages reached the socket` : 'the socket saw none of it');
check('a whole sentence survives, not just the first word', sentence.trim() === PHRASE,
  `reconstructed ${JSON.stringify(sentence)}`);

// This stops at the wire deliberately. Which app receives the characters is decided by whatever
// macOS has in front, so reading them back means driving a window into focus and typing real
// keystrokes into whichever app wins that race — not something a test should gamble on.

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
session.ws.close();
process.exit(failed.length ? 1 : 0);
