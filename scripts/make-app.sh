#!/bin/bash
# Assembles and ad-hoc signs Pixelwash.app from the SwiftPM-built executable.
# Usage: make-app.sh <path-to-PixelwashApp-binary> <output.app>
set -euo pipefail
cd "$(dirname "$0")/.."

binary="$1"
app="$2"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Pixelwash"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Resources/pixelwash.entitlements "$app"
echo "Built $app"
