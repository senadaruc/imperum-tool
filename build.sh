#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/WSMonitor.app"

swift build -c release
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/WSMonitor "$APP/Contents/MacOS/WSMonitor"

codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/WSMonitor"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built + signed: $APP"
