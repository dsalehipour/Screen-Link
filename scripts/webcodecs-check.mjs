/**
 * Answers one question: after a user clicks through the certificate interstitial on a self-signed
 * HTTPS origin, is WebCodecs still available? If it is, the phone works before any real domain
 * exists and the certificate authority work is only about removing the warning.
 */
import { Session } from './cdp.mjs';

const ORIGIN = process.argv[2] ?? 'https://192.168.86.237:8443/';

const session = await Session.attach();
console.log('landed on:', await session.open(ORIGIN));

const report = await session.evaluate(`JSON.stringify({
  url: location.href,
  protocol: location.protocol,
  isSecureContext,
  hasVideoDecoder: typeof VideoDecoder !== 'undefined',
  hasMediaSource: typeof MediaSource !== 'undefined',
})`);

console.log('result:', report);
session.ws.close();
