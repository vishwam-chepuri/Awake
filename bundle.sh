#!/bin/sh
# Assemble Awake.app from the SwiftPM build product.
# Usage: ./bundle.sh [debug|release]   -> prints the .app path
set -eu
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=".build/Awake.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Awake" "$APP/Contents/MacOS/Awake"
cp Info.plist "$APP/Contents/Info.plist"

# ponytail: ad-hoc signature is enough to launch locally. The privileged helper
# (milestone 7) needs a real Developer ID identity — swap `-` for it then.
codesign --force --sign - "$APP"

echo "$APP"
