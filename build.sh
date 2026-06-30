#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/WSMonitor.app"

swift build -c release
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/WSMonitor "$APP/Contents/MacOS/WSMonitor"
cp .build/release/WSHelper "$APP/Contents/MacOS/WSHelper"
cp Resources/io.imperum.wsmonitor.helper.plist "$APP/Contents/Library/LaunchDaemons/"

# Sign inner executables first, then the bundle (outside-in last).
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/WSHelper"
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/WSMonitor"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built + signed: $APP (with privileged helper)"
