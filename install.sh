#!/bin/sh
# Build a release bundle and install it to /Applications, replacing any running copy.
set -eu
cd "$(dirname "$0")"

APP="$(./bundle.sh release | tail -1)"
DEST="/Applications/Awake.app"

pkill -f "$DEST/Contents/MacOS/Awake" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"

echo "installed and launched: $DEST"
