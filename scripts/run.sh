#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/screenlink.app"
PORT="${PORT:-8766}"

if [ ! -d "$APP" ]; then
  echo "no app bundle; run scripts/build.sh first" >&2
  exit 1
fi

mkdir -p "$ROOT/build"
TOKEN_FILE="$ROOT/build/token"
[ -f "$TOKEN_FILE" ] || openssl rand -hex 16 > "$TOKEN_FILE"
TOKEN="$(cat "$TOKEN_FILE")"
LOG="$ROOT/build/screenlink.log"

pkill -f "screenlink.app/Contents/MacOS/screenlink" 2>/dev/null || true
sleep 0.3
: > "$LOG"

# Launched through `open` so launchd owns the process. Running the binary straight from a shell
# makes the terminal the responsible process, and macOS then attributes the screen recording
# permission to the terminal instead of to this app.
open "$APP" --args \
  --token "$TOKEN" \
  --client "$ROOT/Client/index.html" \
  --log "$LOG" \
  --port "$PORT" \
  "$@"

sleep 1.2
echo
echo "  open:  http://127.0.0.1:${PORT}/?token=${TOKEN}"
echo "  stop:  scripts/stop.sh"
echo
tail -f "$LOG"
