/**
 * Minimal Chrome DevTools Protocol driver.
 *
 * The IDE's embedded browser cannot render the certificate interstitial that a self-signed origin
 * puts up, so anything that has to be checked in a browser is checked in a real Chromium build
 * launched here.
 */
const CDP = 'http://127.0.0.1:9222';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function findPage() {
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

export class Session {
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

  static async attach() {
    const page = await findPage();
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve) => ws.addEventListener('open', resolve));
    const session = new Session(ws);
    await session.send('Page.enable');
    await session.send('Runtime.enable');
    // The interstitial only accepts keystrokes while the window has focus.
    await session.send('Page.bringToFront');
    return session;
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve) => this.pending.set(id, resolve));
  }

  async evaluate(expression) {
    const reply = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    const thrown = reply.result?.exceptionDetails;
    if (thrown) throw new Error(thrown.exception?.description ?? thrown.text);
    return reply.result?.result?.value;
  }

  /**
   * The certificate interstitial has no input field. It compares `event.keyCode` on each keypress
   * against the bypass phrase, so the character code has to be dispatched explicitly; a bare `text`
   * produces a keypress with keyCode 0 and the sequence never advances.
   */
  async typeBypass() {
    for (const char of 'thisisunsafe') {
      const charCode = char.charCodeAt(0);
      const code = `Key${char.toUpperCase()}`;
      const virtualKeyCode = char.toUpperCase().charCodeAt(0);
      await this.send('Input.dispatchKeyEvent', {
        type: 'rawKeyDown', key: char, code,
        windowsVirtualKeyCode: virtualKeyCode, nativeVirtualKeyCode: virtualKeyCode,
      });
      await this.send('Input.dispatchKeyEvent', {
        type: 'char', key: char, code, text: char, unmodifiedText: char,
        windowsVirtualKeyCode: charCode, nativeVirtualKeyCode: charCode,
      });
      await this.send('Input.dispatchKeyEvent', {
        type: 'keyUp', key: char, code,
        windowsVirtualKeyCode: virtualKeyCode, nativeVirtualKeyCode: virtualKeyCode,
      });
      await sleep(40);
    }
  }

  /** Navigates, clicking through the self-signed certificate warning if one appears. */
  async open(url) {
    // Navigating to the address already showing, differing only in the fragment, is a no-op in the
    // browser. A run would then silently test the previously loaded page.
    await this.send('Page.navigate', { url: 'about:blank' });
    await sleep(200);
    await this.send('Page.navigate', { url });
    await sleep(2500);
    if (String(await this.evaluate('location.href')).startsWith('chrome-error')) {
      await this.typeBypass();
      await sleep(3500);
    }
    return this.evaluate('location.href');
  }
}
