# screenlink-certs

Issues genuinely trusted TLS certificates to screenlink installs, so a phone can reach a Mac over
HTTPS on the local network without a certificate warning.

## Why this exists

A browser will not run WebCodecs, or a service worker, or most modern media APIs, outside a secure
context. Serving HTTPS from a LAN address means presenting a certificate, and no certificate
authority will issue one for `192.168.x.x`. Self-signed works but costs the user a "Your connection
is not private" screen on every device, which is both bad onboarding and a habit worth not teaching.

The way out is a domain you control. A hostname under that domain resolves, in public DNS, to the
Mac's private address. The phone resolves it publicly, connects locally, and sees a certificate
issued for a real name. No stream traffic leaves the network; DNS is the only part that touches the
internet.

Plex solves the same problem the same way with `*.plex.direct`.

## How it differs from the Plex approach

Plex ships one wildcard certificate and its private key inside the application, which means the key
can be extracted from any copy. Here each install generates its own key and sends a certificate
signing request; the service signs it via ACME and returns only the certificate.

The practical consequences:

- No private key is ever transmitted, stored, or present in this database.
- A compromise of this service cannot impersonate anyone's Mac.
- Hostnames are one label deep (`<install>.<zone>`), so an ordinary certificate covers them and no
  wildcard is needed.

## Flow

1. The install generates an Ed25519 identity key and `POST /v1/installs` with the public half.
   It receives an install id and its hostname.
2. It reports its local address to `POST /v1/installs/:id/address`, which upserts an A record.
3. It generates a TLS key and CSR, then calls `POST /v1/installs/:id/certificate`.
   The service completes a DNS-01 challenge and returns the signed chain.
4. It re-reports its address whenever the network changes, and renews before expiry.

Every request after registration is signed with the identity key and carries an increasing nonce,
because the install id travels in URLs and DNS and is not a secret.

## Deploying

`render.yaml` provisions the web service and Postgres. Set the secrets marked `sync: false` in the
Render dashboard:

| Variable | Where it comes from |
| --- | --- |
| `SCREENLINK_ZONE` | the domain you registered |
| `CLOUDFLARE_ZONE_ID` | Cloudflare dashboard, zone overview |
| `CLOUDFLARE_API_TOKEN` | scoped token with `Zone.DNS:Edit` on that zone only |
| `ACME_CONTACT_EMAIL` | where Let's Encrypt sends expiry warnings |
| `ACME_ACCOUNT_KEY` | `npm run account-key`, generated once and kept |

## Two constraints worth knowing before you scale

**Let's Encrypt allows 50 certificates per registered domain per week.** That is a ceiling on new
installs, not on renewals of existing ones. `ACME_DIRECTORY` points at staging by default so that
development does not consume it. Going past 50 real installs a week requires applying to Let's
Encrypt for a rate limit increase, which they grant for this kind of service.

**Render's filesystem is ephemeral.** Everything durable lives in Postgres. Note that the free
database plan expires after 30 days and free web services spin down after 15 minutes idle, which
adds a cold start to the first registration.
