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
# App Store Connect API key for notarytool, kept out of git: copy
# .release.env.example to .release.env and fill it in.
ENV_FILE="$(dirname "$0")/.release.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (see .release.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
for v in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do [ -n "${!v:-}" ] || { echo "$v not set in $ENV_FILE" >&2; exit 1; }; done
KEY="$ASC_KEY_PATH"; KEY_ID="$ASC_KEY_ID"; ISSUER="$ASC_ISSUER_ID"

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
