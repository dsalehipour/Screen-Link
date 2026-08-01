#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/screenlink.app"

echo "==> building release binary"
swift build -c release

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/screenlink" "$APP/Contents/MacOS/screenlink"
cp -R "$ROOT/Client" "$APP/Contents/Resources/client"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>screenlink</string>
	<key>CFBundleIdentifier</key>
	<string>com.screenlink.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>screenlink</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

# TCC keys screen recording and accessibility off the code signature. With a certificate the
# requirement is identifier + certificate leaf, which survives rebuilds; ad-hoc falls back to a
# cdhash pin, which does not.
KEYCHAIN="$HOME/Library/Keychains/screenlink-signing.keychain-db"
SIGN_ID=""
if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p screenlink "$KEYCHAIN" 2>/dev/null || true
  SIGN_ID=$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk '/screenlink-dev/ {print $2; exit}')
fi

if [ -n "$SIGN_ID" ]; then
  echo "==> signing with stable identity $SIGN_ID"
  codesign --force --sign "$SIGN_ID" --identifier com.screenlink.app --keychain "$KEYCHAIN" "$APP"
else
  echo "==> ad-hoc signing"
  echo "    (run scripts/setup-signing.sh once to stop re-granting permissions on every build)"
  codesign --force --sign - --identifier com.screenlink.app "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo
echo "built $APP"
echo "requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "run: scripts/run.sh"
