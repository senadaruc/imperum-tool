#!/bin/bash
# Notarize + staple "build/Imperum Tool.app" with Apple's notary service.
# Run ./build.sh first (signs the app). Optional for local use — only needed
# to share the .app without Gatekeeper warnings.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Imperum Tool.app"
ZIP="build/ImperumTool.zip"
# App Store Connect API key for notarytool, kept out of git: copy
# .release.env.example to .release.env and fill it in.
ENV_FILE="$(dirname "$0")/.release.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (see .release.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
for v in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do [ -n "${!v:-}" ] || { echo "$v not set in $ENV_FILE" >&2; exit 1; }; done
KEY="$ASC_KEY_PATH"; KEY_ID="$ASC_KEY_ID"; ISSUER="$ASC_ISSUER_ID"

[ -d "$APP" ] || { echo "Run ./build.sh first ($APP missing)"; exit 1; }

/bin/rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"
echo "Notarized + stapled: $APP"
