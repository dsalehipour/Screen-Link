import { createPublicKey, verify } from 'node:crypto';

/**
 * Every request after registration is signed by the install's Ed25519 key.
 *
 * Without this, knowing someone's install id would be enough to repoint their hostname or obtain a
 * certificate for it. The id travels in URLs and DNS, so it must not be treated as a secret.
 */
export function verifySignature(params: {
  publicKeyBase64: string;
  signatureBase64: string;
  message: string;
}): boolean {
  try {
    const key = createPublicKey({
      key: Buffer.concat([
        // DER prefix for an Ed25519 SubjectPublicKeyInfo, so callers can send the bare 32-byte key.
        Buffer.from('302a300506032b6570032100', 'hex'),
        Buffer.from(params.publicKeyBase64, 'base64'),
      ]),
      format: 'der',
      type: 'spki',
    });
    return verify(null, Buffer.from(params.message), key, Buffer.from(params.signatureBase64, 'base64'));
  } catch {
    return false;
  }
}

/**
 * Canonical string that a client signs. Binding the nonce and body into the signature is what stops
 * a captured request from being replayed later, or retargeted at a different endpoint.
 */
export function signingMessage(params: {
  method: string;
  path: string;
  nonce: number;
  body: string;
}): string {
  return [params.method.toUpperCase(), params.path, String(params.nonce), params.body].join('\n');
}
