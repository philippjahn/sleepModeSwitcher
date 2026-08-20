#!/usr/bin/env bash
# Builds the release binary and assembles a signed SleepModeSwitcher.app bundle.
set -euo pipefail

APP_NAME="SleepModeSwitcher"
BUNDLE_ID="com.philippjahn.SleepModeSwitcher"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP="$ROOT/$APP_NAME.app"

ICON="$ROOT/Resources/AppIcon.icns"

echo "▸ Building (release) …"
cd "$ROOT"
swift build -c release

# The icon is checked in; re-render it only when the drawing changed, since
# compiling the script costs a few seconds.
if [ ! -f "$ICON" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON" ]; then
    echo "▸ Rendering app icon …"
    swift "$ROOT/scripts/make-icon.swift" "$ICON"
fi

echo "▸ Assembling $APP_NAME.app …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <!-- macOS treats the Wi-Fi network name as location data. The permission
         is only used to skip the network question when already connected to
         the stored network; no coordinates are ever read. -->
    <key>NSLocationUsageDescription</key>
    <string>macOS only reveals the current Wi-Fi network's name to apps with location access. It is used solely to skip the network question when you are already on your default network.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS only reveals the current Wi-Fi network's name to apps with location access. It is used solely to skip the network question when you are already on your default network.</string>
</dict>
</plist>
PLIST

# Signing identity: $SIGN_IDENTITY, else the machine-local .signing-identity
# file, else ad-hoc.
#
# The identity matters beyond Gatekeeper: TCC ties the Accessibility approval to
# the app's designated requirement. Ad-hoc signing makes that the binary hash,
# so every rebuild invalidates the approval while still showing a ticked box in
# System Settings. A certificate makes it the certificate instead, and the
# approval survives rebuilds. Any self-signed "Code Signing" certificate from
# Keychain Access → Certificate Assistant does the job; it need not be trusted.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$ROOT/.signing-identity" ]; then
    SIGN_IDENTITY="$(tr -d '[:space:]' < "$ROOT/.signing-identity")"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "▸ Code signing ($SIGN_IDENTITY) …"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "▸ Code signing (ad-hoc — Accessibility approval will not survive rebuilds) …"
    codesign --force --deep --sign - "$APP"
fi

# Finder caches icons per bundle; bumping the mtime makes it pick up a changed
# one instead of showing the previous (or the generic) icon.
touch "$APP"

echo "✓ Done: $APP"
echo "  Tip: Move the app to /Applications for more stable login-item autostart."
echo "  Start: open \"$APP\""
