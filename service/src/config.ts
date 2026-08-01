function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing required environment variable ${name}`);
  return value;
}

function optional(name: string, fallback: string): string {
  return process.env[name] ?? fallback;
}

export const config = {
  // Render supplies PORT and expects the process to bind 0.0.0.0 on it.
  port: Number(optional('PORT', '3000')),
  host: '0.0.0.0',

  databaseUrl: required('DATABASE_URL'),

  /** Zone that install hostnames are created under, e.g. "screenlink.example". */
  zone: required('SCREENLINK_ZONE'),
  cloudflareZoneId: required('CLOUDFLARE_ZONE_ID'),
  cloudflareApiToken: required('CLOUDFLARE_API_TOKEN'),

  /**
   * Staging has effectively no rate limit and issues untrusted certificates; production is capped
   * at 50 certificates per registered domain per week. Develop against staging or a handful of
   * test installs will exhaust a week of real issuance.
   */
  acmeDirectory: optional(
    'ACME_DIRECTORY',
    'https://acme-staging-v02.api.letsencrypt.org/directory',
  ),
  acmeContactEmail: required('ACME_CONTACT_EMAIL'),
  /** PEM account key. Generated once and kept, so the ACME account survives redeploys. */
  acmeAccountKey: required('ACME_ACCOUNT_KEY'),

  registrationsPerHourPerIp: Number(optional('REGISTRATIONS_PER_HOUR_PER_IP', '5')),
  /** Renew this far ahead of expiry; Let's Encrypt certificates last 90 days. */
  renewBeforeDays: Number(optional('RENEW_BEFORE_DAYS', '30')),
} as const;
