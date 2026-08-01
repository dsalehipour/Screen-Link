import { randomBytes } from 'node:crypto';
import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify';
import { certificateExpiry, signCertificate } from './acme.js';
import { signingMessage, verifySignature } from './auth.js';
import { config } from './config.js';
import {
  consumeNonce,
  createInstall,
  type Install,
  findInstall,
  migrate,
  recentRegistrations,
  recordRegistration,
  setLanAddress,
  storeCertificate,
} from './db.js';
import { setAddress } from './dns.js';

const app = Fastify({ logger: true });

const hostnameFor = (installId: string) => `${installId}.${config.zone}`;

/** RFC 1918 and loopback only: the whole design assumes the phone is already on the same network. */
function isPrivateAddress(address: string): boolean {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = parts;
  return a === 10 || a === 127 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31);
}

/**
 * Authenticates a signed request and burns its nonce.
 * Returns the install on success, or null after already sending an error response.
 */
async function authenticate(
  request: FastifyRequest<{ Params: { id: string } }>,
  reply: FastifyReply,
): Promise<Install | null> {
  const installId = request.params.id;
  const signature = request.headers['x-screenlink-signature'] as string | undefined;
  const nonce = Number(request.headers['x-screenlink-nonce']);

  if (!signature || !Number.isSafeInteger(nonce)) {
    reply.code(401).send({ error: 'missing signature or nonce' });
    return null;
  }

  const install = await findInstall(installId);
  if (!install) {
    reply.code(404).send({ error: 'unknown install' });
    return null;
  }

  const message = signingMessage({
    method: request.method,
    path: request.url.split('?')[0],
    nonce,
    body: request.body ? JSON.stringify(request.body) : '',
  });

  if (!verifySignature({ publicKeyBase64: install.public_key, signatureBase64: signature, message })) {
    reply.code(401).send({ error: 'bad signature' });
    return null;
  }

  // Checked after the signature so a replayed-but-invalid request cannot advance the counter.
  if (!(await consumeNonce(installId, nonce))) {
    reply.code(409).send({ error: 'nonce must increase' });
    return null;
  }

  return install;
}

app.get('/healthz', async () => ({ ok: true }));

/**
 * Claims a hostname. The only unauthenticated endpoint, and therefore the only one that can burn
 * Let's Encrypt quota, so it is rate limited per source address.
 */
app.post('/v1/installs', async (request, reply) => {
  const body = request.body as { publicKey?: string };
  if (!body?.publicKey || Buffer.from(body.publicKey, 'base64').length !== 32) {
    return reply.code(400).send({ error: 'publicKey must be a base64 Ed25519 key' });
  }

  const sourceIp = request.ip;
  if ((await recentRegistrations(sourceIp)) >= config.registrationsPerHourPerIp) {
    return reply.code(429).send({ error: 'too many registrations from this address' });
  }
  await recordRegistration(sourceIp);

  // 16 bytes keeps the label short enough to read aloud while remaining unguessable, so nobody can
  // enumerate hostnames to discover which addresses are running screenlink.
  const installId = randomBytes(16).toString('hex');
  await createInstall(installId, body.publicKey);

  return { installId, hostname: hostnameFor(installId) };
});

/** Repoints the hostname, for when the Mac changes networks or its DHCP lease. */
app.post<{ Params: { id: string } }>('/v1/installs/:id/address', async (request, reply) => {
  const install = await authenticate(request, reply);
  if (!install) return;

  const body = request.body as { address?: string };
  if (!body?.address || !isPrivateAddress(body.address)) {
    return reply.code(400).send({ error: 'address must be a private IPv4 address' });
  }

  const hostname = hostnameFor(install.id);
  await setAddress(hostname, body.address);
  await setLanAddress(install.id, body.address);
  return { hostname, address: body.address };
});

/**
 * Signs a certificate signing request produced on the Mac.
 * No private key is accepted, stored, or returned; only the install can use what comes back.
 */
app.post<{ Params: { id: string } }>('/v1/installs/:id/certificate', async (request, reply) => {
  const install = await authenticate(request, reply);
  if (!install) return;

  const body = request.body as { csr?: string };
  if (!body?.csr?.includes('BEGIN CERTIFICATE REQUEST')) {
    return reply.code(400).send({ error: 'csr must be a PEM certificate signing request' });
  }

  const hostname = hostnameFor(install.id);
  // The A record has to exist before validation, and it is what the phone will resolve afterwards.
  if (!install.lan_address) {
    return reply.code(409).send({ error: 'register an address before requesting a certificate' });
  }

  try {
    const certificatePem = await signCertificate(hostname, body.csr);
    const expiresAt = certificateExpiry(certificatePem);
    await storeCertificate({ installId: install.id, hostname, certificatePem, expiresAt });
    return { hostname, certificate: certificatePem, expiresAt };
  } catch (error) {
    request.log.error({ error }, 'certificate issuance failed');
    return reply.code(502).send({ error: 'issuance failed' });
  }
});

const start = async () => {
  await migrate();
  await app.listen({ port: config.port, host: config.host });
};

start().catch((error) => {
  app.log.error(error);
  process.exit(1);
});
