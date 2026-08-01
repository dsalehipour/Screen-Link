import { requireIssuance } from './config.js';

const API = 'https://api.cloudflare.com/client/v4';

interface CloudflareRecord {
  id: string;
  name: string;
  type: string;
  content: string;
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${requireIssuance().cloudflareApiToken}`,
      'content-type': 'application/json',
      ...init.headers,
    },
  });

  const body = (await response.json()) as { success: boolean; result: T; errors?: unknown };
  if (!response.ok || !body.success) {
    throw new Error(`cloudflare ${path} failed: ${JSON.stringify(body.errors ?? body)}`);
  }
  return body.result;
}

async function findRecord(name: string, type: string): Promise<CloudflareRecord | undefined> {
  const records = await call<CloudflareRecord[]>(
    `/zones/${requireIssuance().cloudflareZoneId}/dns_records?type=${type}&name=${encodeURIComponent(name)}`,
  );
  return records[0];
}

async function upsert(name: string, type: string, content: string, ttl: number): Promise<void> {
  const existing = await findRecord(name, type);
  const payload = JSON.stringify({ type, name, content, ttl, proxied: false });

  if (existing) {
    await call(`/zones/${requireIssuance().cloudflareZoneId}/dns_records/${existing.id}`, {
      method: 'PUT',
      body: payload,
    });
  } else {
    await call(`/zones/${requireIssuance().cloudflareZoneId}/dns_records`, { method: 'POST', body: payload });
  }
}

/**
 * Points a hostname at an install's local address.
 *
 * The address is deliberately private. Public DNS resolves it, but only a device already on the
 * same network can connect, so the stream never leaves the LAN — DNS is the only part of this that
 * touches the internet.
 */
export async function setAddress(hostname: string, address: string): Promise<void> {
  // Short TTL because laptops move between networks and get new DHCP leases.
  await upsert(hostname, 'A', address, 60);
}

export async function setChallenge(hostname: string, value: string): Promise<void> {
  await upsert(`_acme-challenge.${hostname}`, 'TXT', value, 60);
}

export async function clearChallenge(hostname: string): Promise<void> {
  const record = await findRecord(`_acme-challenge.${hostname}`, 'TXT');
  if (!record) return;
  await call(`/zones/${requireIssuance().cloudflareZoneId}/dns_records/${record.id}`, { method: 'DELETE' });
}
