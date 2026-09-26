#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/Imperum Tool.app"

swift build -c release
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ImperumTool "$APP/Contents/MacOS/ImperumTool"
cp .build/release/copystack "$APP/Contents/MacOS/copystack"

codesign --force --options runtime --timestamp --identifier io.imperum.tool.copystack --sign "$ID" "$APP/Contents/MacOS/copystack"
codesign --force --options runtime --timestamp --entitlements Resources/ImperumTool.entitlements --sign "$ID" "$APP/Contents/MacOS/ImperumTool"
codesign --force --options runtime --timestamp --entitlements Resources/ImperumTool.entitlements --sign "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" | grep -q apple-events || { echo "entitlements missing"; exit 1; }
echo "Built + signed: $APP"
