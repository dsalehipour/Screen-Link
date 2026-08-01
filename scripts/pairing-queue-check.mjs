/**
 * Checks that the prompt on the Mac is always about a device that is still waiting.
 *
 * This is the case the main pairing suite misses, because it only ever has one device in flight.
 * A phone that asks and then gives up used to leave its prompt on screen: the next person to look
 * at the Mac would approve a dead request while their actual phone sat there, and the six-digit
 * code — the one thing stopping someone else's request being approved by mistake — would be the
 * wrong one.
 */
import { approve, promptText, sleep } from './approve.mjs';

const ORIGIN = process.argv[2] ?? 'ws://127.0.0.1:8766';
const TOKEN = process.argv[3];

if (!TOKEN) {
  console.error('usage: pairing-queue-check.mjs <ws-origin> <token>');
  process.exit(2);
}

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

function connect(name) {
  const ws = new WebSocket(ORIGIN);
  const state = { name, code: null, outcome: null, ws };
  ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', token: TOKEN, deviceName: name }));
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return;
    const msg = JSON.parse(e.data);
    if (msg.type === 'pairing') state.code = msg.code;
    if (msg.type === 'paired') state.outcome = 'paired';
    if (msg.type === 'denied') state.outcome = 'denied';
  };
  return state;
}

const abandoned = connect('abandoned phone');
await sleep(2000);
check('a waiting device raises a prompt', (await promptText())?.includes(abandoned.code) === true,
  `code=${abandoned.code}`);

abandoned.ws.close();
await sleep(1500);
check('the prompt goes away when that device does', (await promptText()) === null,
  `still showing: ${await promptText()}`);

const live = connect('waiting phone');
await sleep(2000);
const showing = await promptText();
check('the next device gets its own prompt', showing?.includes(live.code) === true,
  `showing ${JSON.stringify(showing)}, expected code ${live.code}`);

await approve(live.code);
await sleep(1500);
check('approving reaches the device that asked', live.outcome === 'paired',
  `outcome=${live.outcome}`);

live.ws.close();
await sleep(800);
check('nothing is left on screen afterwards', (await promptText()) === null);

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
