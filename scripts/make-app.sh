#!/bin/bash
# Assembles and ad-hoc signs Pixelwash.app from the SwiftPM-built executable.
# Usage: make-app.sh <path-to-PixelwashApp-binary> <output.app>
set -euo pipefail
cd "$(dirname "$0")/.."

binary="$1"
app="$2"

mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/Pixelwash"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/pixelwash.entitlements "$app"
echo "Built $app"
