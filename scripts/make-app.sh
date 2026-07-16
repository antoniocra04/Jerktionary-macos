#!/bin/bash
# Builds the release binary and assembles Jerktionary.app in ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Jerktionary"
APP="dist/Jerktionary.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jerktionary"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for local use; TCC grants stick to the bundle id.
codesign --force --sign - "$APP"

echo "Built $APP"
