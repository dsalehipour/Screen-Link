import acme from 'acme-client';
import { config } from './config.js';
import { clearChallenge, setChallenge } from './dns.js';

let client: acme.Client | undefined;

async function acmeClient(): Promise<acme.Client> {
  if (client) return client;
  client = new acme.Client({
    directoryUrl: config.acmeDirectory,
    accountKey: config.acmeAccountKey,
  });
  await client.createAccount({ termsOfServiceAgreed: true, contact: [`mailto:${config.acmeContactEmail}`] });
  return client;
}

/**
 * Signs an install's certificate signing request.
 *
 * DNS-01 rather than HTTP-01 because the name resolves to a private address that Let's Encrypt
 * cannot reach. Proving control of the zone is something this service can do; proving control of
 * someone's living room is not.
 *
 * The CSR carries the install's own public key, so the returned certificate is only usable by
 * whoever holds the matching private key. That key never leaves the Mac and is never sent here.
 */
export async function signCertificate(hostname: string, csrPem: string): Promise<string> {
  const client = await acmeClient();

  return client.auto({
    csr: csrPem,
    email: config.acmeContactEmail,
    termsOfServiceAgreed: true,
    challengePriority: ['dns-01'],
    challengeCreateFn: async (_authz, challenge, keyAuthorization) => {
      if (challenge.type !== 'dns-01') throw new Error(`unexpected challenge ${challenge.type}`);
      await setChallenge(hostname, keyAuthorization);
      // Cloudflare is fast but not instant, and the validation servers will not retry forever.
      await new Promise((resolve) => setTimeout(resolve, 15_000));
    },
    challengeRemoveFn: async () => {
      await clearChallenge(hostname);
    },
  });
}

/** Reads the notAfter date without a certificate parsing dependency. */
export function certificateExpiry(certificatePem: string): Date {
  const info = acme.crypto.readCertificateInfo(certificatePem);
  return info.notAfter;
}
