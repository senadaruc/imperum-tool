#!/bin/bash
# Package "build/Imperum Tool.app" into a signed, notarized, stapled DMG.
# Run ./build.sh (and ideally ./notarize.sh) first. The DMG itself is also
# notarized + stapled so it opens cleanly on any Mac, even offline.
set -euo pipefail
cd "$(dirname "$0")"

ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/Imperum Tool.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG="build/ImperumTool-$VERSION.dmg"
STAGING="build/dmg-staging"
KEY="$HOME/.secrets/imperum/AuthKey_UB3PR8KXU8.p8"
KEY_ID="UB3PR8KXU8"
ISSUER="3eb5d7ab-66f4-448f-b174-165413a98055"

[ -d "$APP" ] || { echo "Run ./build.sh first ($APP missing)"; exit 1; }

/bin/rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto --norsrc "$APP" "$STAGING/Imperum Tool.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Imperum Tool" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
/bin/rm -rf "$STAGING"

codesign --force --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" || true
echo "Done: $DMG"
