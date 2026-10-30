#!/bin/bash
# Builds a Developer ID-signed, notarized "PDF Text Editor.app" and zips it into build/release.
# One-time: xcrun notarytool store-credentials tasker-notary --apple-id <you> --team-id SZVSSCJQFN
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="Developer ID Application: Alexey Romadinov (SZVSSCJQFN)"
PROFILE="${NOTARY_PROFILE:-tasker-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

./build.sh
rm -rf build/release
mkdir -p build/release
APP="build/release/PDF Text Editor.app"
ZIP="build/release/PDF-Text-Editor-$VERSION.zip"
ditto "build/PDF Text Editor.app" "$APP"

# Hardened runtime and a secure timestamp are required for notarization.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the download carries the stapled ticket (Gatekeeper accepts it offline).
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

echo "Notarized: $APP (zip: $ZIP)"
echo "Publish: git tag v$VERSION && git push origin v$VERSION && gh release create v$VERSION \"$ZIP\" --verify-tag"
