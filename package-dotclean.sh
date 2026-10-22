#!/usr/bin/env bash
# Package DotClean as a signed, notarized, stapled disk image.
# Output: packages/dotclean.<version>.dmg
#
# Prereqs: Developer ID Application: jeff elkins (9Q77WK7W3R) in the keychain,
# notarytool keychain profile "notary-jeff".
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
IDENTITY="Developer ID Application: jeff elkins (9Q77WK7W3R)"
NOTARY_PROFILE="notary-jeff"
OUT_DMG="packages/dotclean.$VERSION.dmg"
VOLNAME="dotclean $VERSION"

echo "=== 1/5 build + assemble ==="
make app

echo "=== 2/5 sign ==="
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" build/DotClean.app
codesign -v --strict build/DotClean.app

echo "=== 3/5 notarize + staple the app ==="
rm -f /tmp/dotclean-app.zip
ditto -c -k --keepParent build/DotClean.app /tmp/dotclean-app.zip
xcrun notarytool submit /tmp/dotclean-app.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/DotClean.app

echo "=== 4/5 build the DMG ==="
STAGE="$(mktemp -d)/dotclean-$VERSION"
mkdir -p "$STAGE" packages
ditto build/DotClean.app "$STAGE/DotClean.app"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md"
cp LICENSE "$STAGE/LICENSE"
rm -f "$OUT_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -format UDZO -ov "$OUT_DMG"

echo "=== 5/5 sign + notarize + staple the DMG ==="
codesign --force --timestamp --sign "$IDENTITY" "$OUT_DMG"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT_DMG"
spctl -a -t open --context context:primary-signature -vv "$OUT_DMG"

echo
echo "=== package: $PWD/$OUT_DMG ==="
ls -lh "$OUT_DMG"
