#!/usr/bin/env bash
# Builds the release artifacts in build/release/:
#   SiliconPulse.dmg   drag-to-Applications disk image (the download link)
#   SiliconPulse.zip   the same app, zipped
#   SHA256SUMS.txt
# Asset names carry no version, so https://github.com/<owner>/<repo>/releases/latest/download/SiliconPulse.dmg
# always points at the newest release.
#
# Signing and notarization are used when their environment is set (see docs/RELEASING.md):
#   SIGN_IDENTITY                          Developer ID Application identity (in the keychain)
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD   app-specific password for notarytool
# Without them the app is ad-hoc signed, which macOS Gatekeeper blocks on other Macs until the user allows it.
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-$(cat VERSION)}"
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

UNIVERSAL=1 scripts/build-app.sh

notarize() {
  [ "$SIGN_IDENTITY" != "-" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] || return 1
  xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
}

NOTARIZED=false
# Notarize the app (submitted as a zip), then staple the ticket so it opens offline too.
if notarize build/SiliconPulse.zip; then
  xcrun stapler staple build/SiliconPulse.app
  NOTARIZED=true
fi
(cd build && rm -f SiliconPulse.zip && ditto -c -k --keepParent SiliconPulse.app SiliconPulse.zip)
cp build/SiliconPulse.zip "$OUT/SiliconPulse.zip"

# Disk image with an Applications shortcut to drag onto.
STAGE="$(mktemp -d)/SiliconPulse"
mkdir -p "$STAGE"
cp -R build/SiliconPulse.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SiliconPulse $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT/SiliconPulse.dmg" >/dev/null
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/SiliconPulse.dmg"
  if $NOTARIZED && notarize "$OUT/SiliconPulse.dmg"; then xcrun stapler staple "$OUT/SiliconPulse.dmg"; fi
fi

# Sanity checks on what users will download.
hdiutil verify "$OUT/SiliconPulse.dmg" >/dev/null
MOUNT="$(mktemp -d)"
hdiutil attach "$OUT/SiliconPulse.dmg" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
codesign --verify --strict --deep "$MOUNT/SiliconPulse.app"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT/SiliconPulse.app/Contents/Info.plist" | grep -qx "$VERSION"
lipo -archs "$MOUNT/SiliconPulse.app/Contents/MacOS/SiliconPulse" | tee /dev/stderr | grep -q "x86_64 arm64\|arm64 x86_64"
spctl --assess --type execute "$MOUNT/SiliconPulse.app" 2>&1 || true
hdiutil detach "$MOUNT" >/dev/null

(cd "$OUT" && shasum -a 256 SiliconPulse.dmg SiliconPulse.zip > SHA256SUMS.txt)
echo "notarized=$NOTARIZED" > "$OUT/signing.txt"
echo "signing=$([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo developer-id)" >> "$OUT/signing.txt"
ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt" "$OUT/signing.txt"
