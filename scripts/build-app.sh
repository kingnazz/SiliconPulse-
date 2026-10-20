#!/usr/bin/env bash
# Builds SiliconPulse in release mode and wraps the executable in a signed .app bundle.
#
#   VERSION        marketing version (default: the VERSION file)
#   SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: Name (TEAMID)"; default "-" (ad-hoc)
#   UNIVERSAL=1    build for Apple Silicon and Intel (release downloads)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/SiliconPulse.app"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product SiliconPulse ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/SiliconPulse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiliconPulse"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
# App icon: Resources/AppIcon.png (1024²) → AppIcon.icns
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Hardened runtime (required for notarization). Ad-hoc ("-") runs locally; downloads need a Developer ID.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - --timestamp=none "$APP"
else
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp "$APP"
fi
codesign --verify --strict "$APP"
(cd build && rm -f SiliconPulse.zip && ditto -c -k --keepParent SiliconPulse.app SiliconPulse.zip)
echo "Built $APP ($VERSION, build $BUILD_NUMBER, signed with ${SIGN_IDENTITY/#-/ad-hoc})"
