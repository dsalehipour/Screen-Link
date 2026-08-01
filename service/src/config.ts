function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required environment variable ${name}`);
  return value;
}

function optional(name: string, fallback: string): string {
  return process.env[name] ?? fallback;
}

/**
 * Everything needed to actually issue certificates, or null until it has been supplied.
 *
 * Kept separate from the rest of the configuration so the service can deploy and pass its health
 * check before a domain exists. Refusing to boot would mean the first deploy crash-loops, which
 * makes it impossible to tell a missing setting apart from a broken build.
 */
function issuanceConfig() {
  const zone = process.env.SCREENLINK_ZONE;
  const cloudflareZoneId = process.env.CLOUDFLARE_ZONE_ID;
  const cloudflareApiToken = process.env.CLOUDFLARE_API_TOKEN;
  const acmeContactEmail = process.env.ACME_CONTACT_EMAIL;
  const acmeAccountKey = process.env.ACME_ACCOUNT_KEY;

  if (!zone || !cloudflareZoneId || !cloudflareApiToken || !acmeContactEmail || !acmeAccountKey) {
    return null;
  }
  return { zone, cloudflareZoneId, cloudflareApiToken, acmeContactEmail, acmeAccountKey };
}

const issuance = issuanceConfig();

export const config = {
  // Render supplies PORT and expects the process to bind 0.0.0.0 on it.
  port: Number(optional('PORT', '3000')),
  host: '0.0.0.0',

  databaseUrl: required('DATABASE_URL'),

  issuance,
  /** False until the domain and its credentials are configured; endpoints answer 503 until then. */
  get configured(): boolean {
    return issuance !== null;
  },

  /**
   * Staging has effectively no rate limit and issues untrusted certificates; production is capped
   * at 50 certificates per registered domain per week. Develop against staging or a handful of
   * test installs will exhaust a week of real issuance.
   */
  acmeDirectory: optional(
    'ACME_DIRECTORY',
    'https://acme-staging-v02.api.letsencrypt.org/directory',
  ),

  registrationsPerHourPerIp: Number(optional('REGISTRATIONS_PER_HOUR_PER_IP', '5')),
  /** Renew this far ahead of expiry; Let's Encrypt certificates last 90 days. */
  renewBeforeDays: Number(optional('RENEW_BEFORE_DAYS', '30')),
} as const;

/** Throws if called before the service is configured; guarded by the 503 check on every route. */
export function requireIssuance() {
  if (!config.issuance) throw new Error('issuance is not configured');
  return config.issuance;
}
