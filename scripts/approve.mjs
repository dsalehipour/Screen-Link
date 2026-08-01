/**
 * Answers the pairing prompt on the Mac from a test.
 *
 * Always approve by code. Clicking whatever prompt happens to be on screen is how a run ends up
 * approving one device while a different one waits, which reads as a product failure and is not one.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const tell = (script) => run('osascript', ['-e',
  `tell application "System Events" to tell process "screenlink" ${script}`]);

/** The text of the prompt currently on screen, or null if there is none. */
export async function promptText() {
  try {
    const { stdout } = await tell('to get value of static text 1 of window 1');
    return stdout.trim();
  } catch {
    return null;
  }
}

/**
 * Waits for the prompt showing `code` and approves it. Passing no code approves whatever is up,
 * which is only appropriate when the test knows nothing else can be waiting.
 */
export async function approve(code, { timeoutMs = 15000, button = 'Approve' } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const text = await promptText();
    if (text && (!code || text.includes(code))) {
      try {
        await tell(`to click button "${button}" of window 1`);
        return true;
      } catch { /* it closed underneath us; fall through and retry */ }
    }
    await sleep(300);
  }
  return false;
}

/** The same, for a page driven over CDP: reads the six-digit code the client is showing. */
export async function approveFromPage(session, options = {}) {
  const deadline = Date.now() + (options.timeoutMs ?? 15000);
  while (Date.now() < deadline) {
    const overlay = await session.evaluate(
      `(() => { const o = document.getElementById('overlay');
                return o.classList.contains('hidden') ? '' : o.textContent; })()`);
    const code = String(overlay ?? '').match(/\b(\d{6})\b/);
    if (code) return approve(code[1], options);
    // No code and no overlay means this device was already approved on a previous run.
    if (overlay === '') return true;
    await sleep(400);
  }
  return false;
}
