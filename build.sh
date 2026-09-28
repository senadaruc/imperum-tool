#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# The bare Command Line Tools cannot compile the SwiftUI macros this app uses.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/Imperum Tool.app"
FW="$APP/Contents/Frameworks/Sparkle.framework"

if grep -q REPLACE_WITH_PUBLIC_ED_KEY Resources/Info.plist; then
  echo "Resources/Info.plist still has the SUPublicEDKey placeholder; run generate_keys and paste the public key" >&2
  exit 1
fi

swift build -c release
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ImperumTool "$APP/Contents/MacOS/ImperumTool"
cp .build/release/copystack "$APP/Contents/MacOS/copystack"
ditto .build/release/Sparkle.framework "$FW"

# Sparkle: sign the nested pieces first, then the framework, then ours.
SIGN=(codesign --force --options runtime --timestamp --sign "$ID")
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"

"${SIGN[@]}" --identifier io.imperum.tool.copystack "$APP/Contents/MacOS/copystack"
"${SIGN[@]}" --entitlements Resources/ImperumTool.entitlements "$APP/Contents/MacOS/ImperumTool"
"${SIGN[@]}" --entitlements Resources/ImperumTool.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" | grep -q apple-events || { echo "entitlements missing"; exit 1; }
echo "Built + signed: $APP"
