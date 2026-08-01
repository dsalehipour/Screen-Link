/**
 * Answers one question: after a user clicks through the certificate interstitial on a self-signed
 * HTTPS origin, is WebCodecs still available?
 *
 * The IDE's embedded browser cannot render the interstitial, so this drives a real Chromium build
 * over CDP and types the bypass phrase exactly as a person would.
 */
const ORIGIN = process.argv[2] ?? 'https://192.168.86.237:8443/';
const CDP = 'http://127.0.0.1:9222';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function target() {
  // Chromium needs a moment to open the debugging port after launch.
  for (let i = 0; i < 40; i++) {
    try {
      const pages = await (await fetch(`${CDP}/json/list`)).json();
      const page = pages.find((p) => p.type === 'page');
      if (page) return page;
    } catch {}
    await sleep(500);
  }
  throw new Error('no debuggable page appeared');
}

class Session {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    ws.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      const resolve = this.pending.get(message.id);
      if (resolve) {
        this.pending.delete(message.id);
        resolve(message);
      }
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve) => this.pending.set(id, resolve));
  }

  async evaluate(expression) {
    const reply = await this.send('Runtime.evaluate', { expression, returnByValue: true });
    return reply.result?.result?.value;
  }

  /**
   * The interstitial has no input field. It compares `event.keyCode` on each keypress against the
   * bypass phrase, so the character code has to be set explicitly; a bare `text` produces a
   * keypress with keyCode 0 and the match never advances.
   */
  async typeBypass() {
    for (const char of 'thisisunsafe') {
      const charCode = char.charCodeAt(0);
      const code = `Key${char.toUpperCase()}`;
      const virtualKeyCode = char.toUpperCase().charCodeAt(0);
      await this.send('Input.dispatchKeyEvent', {
        type: 'rawKeyDown',
        key: char,
        code,
        windowsVirtualKeyCode: virtualKeyCode,
        nativeVirtualKeyCode: virtualKeyCode,
      });
      await this.send('Input.dispatchKeyEvent', {
        type: 'char',
        key: char,
        code,
        text: char,
        unmodifiedText: char,
        windowsVirtualKeyCode: charCode,
        nativeVirtualKeyCode: charCode,
      });
      await this.send('Input.dispatchKeyEvent', {
        type: 'keyUp',
        key: char,
        code,
        windowsVirtualKeyCode: virtualKeyCode,
        nativeVirtualKeyCode: virtualKeyCode,
      });
      await sleep(40);
    }
  }
}

const page = await target();
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve) => ws.addEventListener('open', resolve));
const session = new Session(ws);

await session.send('Page.enable');
await session.send('Runtime.enable');
// The interstitial listens on the focused window, so key events are dropped if it is in the
// background. This is what made the same attempt fail from the embedded browser.
await session.send('Page.bringToFront');
await session.send('Page.navigate', { url: ORIGIN });
await sleep(2500);

const beforeUrl = await session.evaluate('location.href');
console.log('landed on:', beforeUrl);

if (String(beforeUrl).startsWith('chrome-error')) {
  console.log('interstitial shown, typing bypass phrase');
  await session.typeBypass();
  await sleep(3500);
}

const report = await session.evaluate(`JSON.stringify({
  url: location.href,
  protocol: location.protocol,
  isSecureContext,
  hasVideoDecoder: typeof VideoDecoder !== 'undefined',
  hasMediaSource: typeof MediaSource !== 'undefined',
  hasWebSocket: typeof WebSocket !== 'undefined',
})`);

console.log('result:', report ?? '(page did not evaluate)');
ws.close();
