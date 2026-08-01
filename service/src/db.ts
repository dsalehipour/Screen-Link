import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { config } from './config.js';

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  // Render's managed Postgres terminates TLS with a certificate chain the default verifier does
  // not carry. The connection is still encrypted.
  ssl: config.databaseUrl.includes('localhost') ? false : { rejectUnauthorized: false },
});

/**
 * Applied on boot rather than as a release command, because the filesystem is ephemeral and there
 * is no persistent place to track migration state outside the database itself.
 */
export async function migrate(): Promise<void> {
  const here = dirname(fileURLToPath(import.meta.url));
  const sql = await readFile(join(here, '../migrations/001_init.sql'), 'utf8');
  await pool.query(sql);
}

export interface Install {
  id: string;
  public_key: string;
  lan_address: string | null;
  last_nonce: string;
}

export async function findInstall(id: string): Promise<Install | undefined> {
  const result = await pool.query<Install>(
    'select id, public_key, lan_address, last_nonce from installs where id = $1',
    [id],
  );
  return result.rows[0];
}

export async function createInstall(id: string, publicKey: string): Promise<void> {
  await pool.query('insert into installs (id, public_key) values ($1, $2)', [id, publicKey]);
}

/**
 * Advances the replay counter and touches the liveness timestamp in one statement.
 * Returns false when the nonce is not strictly increasing, which means a replayed request.
 */
export async function consumeNonce(id: string, nonce: number): Promise<boolean> {
  const result = await pool.query(
    'update installs set last_nonce = $2, last_seen_at = now() where id = $1 and last_nonce < $2',
    [id, nonce],
  );
  return (result.rowCount ?? 0) > 0;
}

export async function setLanAddress(id: string, address: string): Promise<void> {
  await pool.query('update installs set lan_address = $2 where id = $1', [id, address]);
}

export async function storeCertificate(params: {
  installId: string;
  hostname: string;
  certificatePem: string;
  expiresAt: Date;
}): Promise<void> {
  await pool.query(
    `insert into certificates (install_id, hostname, certificate_pem, issued_at, expires_at)
     values ($1, $2, $3, now(), $4)
     on conflict (install_id) do update
       set certificate_pem = excluded.certificate_pem,
           hostname        = excluded.hostname,
           issued_at       = now(),
           expires_at      = excluded.expires_at`,
    [params.installId, params.hostname, params.certificatePem, params.expiresAt],
  );
}

export async function recentRegistrations(sourceIp: string): Promise<number> {
  const result = await pool.query<{ count: string }>(
    `select count(*) from registration_attempts
      where source_ip = $1 and attempted_at > now() - interval '1 hour'`,
    [sourceIp],
  );
  return Number(result.rows[0]?.count ?? 0);
}

export async function recordRegistration(sourceIp: string): Promise<void> {
  await pool.query('insert into registration_attempts (source_ip) values ($1)', [sourceIp]);
}
