#!/usr/bin/env bash
# Creates a stable self-signed code signing identity so TCC permissions survive rebuilds.
#
# An ad-hoc signature has no certificate, so macOS pins the grant to the binary's cdhash and every
# rebuild looks like a brand new app that must be re-approved. Signing with a certificate instead
# produces a designated requirement of "identifier AND certificate leaf", which stays satisfied no
# matter how many times the code changes.
#
# The identity is self-signed and deliberately untrusted. That is fine: trust settings govern
# signature *verification*, and adding trust would require an admin password. codesign will happily
# sign with an untrusted identity, and TCC only cares that the requirement matches.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/screenlink-signing.keychain-db"
KEYCHAIN_PASS="screenlink"
CERT_NAME="screenlink-dev"
# LibreSSL at this path produces PKCS12 archives macOS can import. Homebrew's OpenSSL 3 defaults to
# a MAC algorithm the system importer rejects with "MAC verification failed".
OPENSSL=/usr/bin/openssl

find_identity() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="$CERT_NAME" '$0 ~ name {print $2; exit}'
}

if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
  if [ -n "$(find_identity)" ]; then
    echo "signing identity already present: $(find_identity)  ($CERT_NAME)"
    exit 0
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = screenlink-dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> generating self-signed code signing certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "pass:$KEYCHAIN_PASS" -name "$CERT_NAME" 2>/dev/null

echo "==> importing into a dedicated keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 36000 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign -A >/dev/null
# Without this, codesign triggers a GUI prompt to allow key access on every signature.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1

if ! security list-keychains -d user | grep -q "screenlink-signing"; then
  echo "==> adding keychain to the user search list"
  CURRENT=$(security list-keychains -d user | sed 's/[",]//g' | xargs)
  # shellcheck disable=SC2086
  security list-keychains -d user -s $CURRENT "$KEYCHAIN"
fi

IDENTITY="$(find_identity)"
if [ -z "$IDENTITY" ]; then
  echo "failed to create signing identity" >&2
  exit 1
fi

echo
echo "created signing identity $IDENTITY ($CERT_NAME)"
echo "scripts/build.sh will now use it automatically."
echo "Grant screenlink its permissions once after the next build; they will persist from then on."
