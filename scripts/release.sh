#!/usr/bin/env bash
# Publishes a GitHub release carrying the built app, so it can be downloaded instead of built.
#
# The asset name never changes. GitHub serves a redirect at releases/latest/download/<asset>, so a
# fixed name is what makes one README link point at the newest build forever. Versioning the
# filename would break that link on every release; the version is inside the app instead, in the
# menu and in /health.
#
# Nothing here is notarized, because that needs an Apple Developer ID. A downloaded copy is
# therefore refused on first open until it is allowed in System Settings, which the release notes
# below explain. Everything else about the signature is real: it carries the certificate from
# setup-signing.sh, which is what lets a downloader's permissions survive updates.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/screenlink.app"
ASSET="$ROOT/build/screenlink.zip"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.1.0" >&2
  exit 1
fi
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "version should look like 0.1.0 or 0.1.0-beta.1, got '$VERSION'" >&2
  exit 1
fi
TAG="v$VERSION"

echo "==> checking the tree is releasable"
command -v gh >/dev/null || { echo "gh is not installed: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ] && [ -z "${ALLOW_BRANCH:-}" ]; then
  echo "on '$BRANCH', not main. Set ALLOW_BRANCH=1 to release anyway." >&2
  exit 1
fi

# A dirty tree produces an artifact that no commit can reproduce, and the build would stamp it
# "-dirty" — which is worth refusing rather than publishing.
if [ -n "$(git status --porcelain)" ]; then
  echo "working tree has uncommitted changes; commit or stash them first" >&2
  git status --short >&2
  exit 1
fi

git fetch origin --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists" >&2
  exit 1
fi
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "HEAD is not on origin/main; push first so the tag points at a commit that exists there" >&2
  exit 1
fi

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"

echo "==> building $TAG"
VERSION="$VERSION" "$ROOT/scripts/build.sh"

# An ad-hoc signature would make every release a different app as far as TCC is concerned, so
# everyone who updated would have to grant screen recording and accessibility again. Worth failing
# the release over rather than discovering from a confused download.
# Captured before matching rather than piped into grep: codesign writes this to stderr a line at a
# time, so `grep -q` exiting on the match leaves codesign writing into a closed pipe, and pipefail
# reports the SIGPIPE as a failed check. The guard then fires on correctly signed builds.
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIGNATURE" != *"Authority=screenlink-dev"* ]]; then
  echo "app is not signed with the screenlink-dev certificate; run scripts/setup-signing.sh" >&2
  exit 1
fi

echo "==> packaging"
# ditto rather than zip: it preserves the extended attributes and symlinks a bundle's signature is
# computed over. A plain zip can arrive with a signature that no longer verifies.
rm -f "$ASSET"
ditto -c -k --keepParent "$APP" "$ASSET"

# Verified on the unpacked copy, because that is what a downloader actually runs. This has to hold
# for permissions to stick, and it is cheap to check.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ASSET" "$CHECK"
codesign --verify --strict "$CHECK/screenlink.app"
echo "    signature survives the round trip: $(du -h "$ASSET" | cut -f1)"

NOTES="$(mktemp)"
cat > "$NOTES" <<EOF
Apple Silicon Mac, macOS 14 or later. Download \`screenlink.zip\`, unzip it, and move
\`screenlink.app\` wherever you keep apps.

**It will refuse to open the first time.** This build is signed but not notarized — that needs a
paid Apple Developer ID — so macOS quarantines it like anything else off the internet. Open it once,
let it be blocked, then go to **System Settings > Privacy & Security**, find the message about
screenlink near the bottom, and click **Open Anyway**. From the terminal,
\`xattr -d com.apple.quarantine /path/to/screenlink.app\` does the same thing.

It then asks for **Screen Recording** and **Accessibility**, which is what it needs to show the
screen and to click on your behalf. Both are granted in the same settings pane. There is no menu bar
icon until it is running, and no window at any point — it lives entirely in the menu bar.

Grant those, click the menu bar icon, turn on **Allow access from my network** or **Reach this Mac
from anywhere**, and scan the QR code with your phone. The [README](https://github.com/dsalehipour/Screen-Link#connect-your-phone)
walks through it.
EOF

if [ -n "$PREVIOUS" ]; then
  printf '\n## Changes since %s\n\n' "$PREVIOUS" >> "$NOTES"
  git log --pretty='- %s' "$PREVIOUS..HEAD" >> "$NOTES"
fi

echo "==> tagging and publishing"
git tag -a "$TAG" -m "screenlink $VERSION"
git push origin "$TAG" --quiet
gh release create "$TAG" "$ASSET" \
  --title "screenlink $VERSION" \
  --notes-file "$NOTES" \
  --target main
rm -f "$NOTES"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo
echo "released $TAG"
echo "always-latest download: https://github.com/$REPO/releases/latest/download/screenlink.zip"
