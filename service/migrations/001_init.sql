-- Each screenlink install that has claimed a hostname under the service domain.
--
-- There is deliberately no private key column anywhere in this schema. Installs generate their own
-- key and send a certificate signing request; the service only ever handles public material, so a
-- database compromise cannot impersonate anyone's Mac.
create table if not exists installs (
    -- Random label that becomes the leftmost part of the hostname. A single label keeps the
    -- hostname one level deep, which is what lets an ordinary certificate cover it.
    id              text primary key,
    -- Ed25519 public key, base64. Every request after registration is signed with its private half.
    public_key      text        not null,
    -- Private address the hostname resolves to. Public DNS pointing at an RFC 1918 address is what
    -- lets a phone reach the Mac directly without any traffic leaving the local network.
    lan_address     inet,
    created_at      timestamptz not null default now(),
    last_seen_at    timestamptz not null default now(),
    -- Replay protection: a signed request must carry a counter above the last one accepted.
    last_nonce      bigint      not null default 0
);

create table if not exists certificates (
    install_id      text primary key references installs (id) on delete cascade,
    hostname        text        not null,
    certificate_pem text        not null,
    issued_at       timestamptz not null default now(),
    expires_at      timestamptz not null
);

-- Renewal sweeps look up certificates by expiry, not by install.
create index if not exists certificates_expires_at_idx on certificates (expires_at);

-- Registration is the one unauthenticated endpoint, so it is the one that needs abuse accounting.
-- Let's Encrypt allows only 50 certificates per registered domain per week, which makes a burst of
-- junk registrations an availability problem for real users rather than just noise.
create table if not exists registration_attempts (
    source_ip   inet        not null,
    attempted_at timestamptz not null default now()
);

create index if not exists registration_attempts_recent_idx
    on registration_attempts (source_ip, attempted_at desc);
