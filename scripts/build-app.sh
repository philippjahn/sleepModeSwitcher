#!/usr/bin/env bash
# Builds the release binary and assembles a signed SleepModeSwitcher.app bundle.
set -euo pipefail

APP_NAME="SleepModeSwitcher"
BUNDLE_ID="com.philippjahn.SleepModeSwitcher"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP="$ROOT/$APP_NAME.app"

echo "▸ Building (release) …"
cd "$ROOT"
swift build -c release

echo "▸ Assembling $APP_NAME.app …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Sleep Mode Switcher</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "▸ Code signing (ad-hoc) …"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP"
echo "  Tip: Move the app to /Applications for more stable login-item autostart."
echo "  Start: open \"$APP\""
