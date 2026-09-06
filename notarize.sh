#!/bin/bash
# Notarize + staple "build/Imperum Tool.app" with Apple's notary service.
# Run ./build.sh first (signs the app). Optional for local use — only needed
# to share the .app without Gatekeeper warnings.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Imperum Tool.app"
ZIP="build/ImperumTool.zip"
KEY="$HOME/.secrets/imperum/AuthKey_UB3PR8KXU8.p8"
KEY_ID="UB3PR8KXU8"
ISSUER="3eb5d7ab-66f4-448f-b174-165413a98055"   # Imperum B.V. ASC API issuer

[ -d "$APP" ] || { echo "Run ./build.sh first ($APP missing)"; exit 1; }

/bin/rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"
echo "Notarized + stapled: $APP"
