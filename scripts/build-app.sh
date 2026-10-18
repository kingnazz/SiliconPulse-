#!/usr/bin/env bash
# Builds SiliconPulse in release mode and wraps the executable in a signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/SiliconPulse.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c "$CONFIG" --product SiliconPulse
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SiliconPulse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiliconPulse"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# Ad-hoc signature so the app launches locally; distribute with a Developer ID signature instead.
codesign --force --sign - --timestamp=none "$APP"
(cd build && rm -f SiliconPulse.zip && ditto -c -k --keepParent SiliconPulse.app SiliconPulse.zip)
echo "Built $APP"
