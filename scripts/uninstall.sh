#!/usr/bin/env bash
# Removes the sudoers rule and (optionally) the built app, and restores normal
# sleep behaviour.
set -euo pipefail

DEST="/etc/sudoers.d/sleepmodeswitcher"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SleepModeSwitcher.app"

echo "▸ Restoring normal sleep (disablesleep 0) …"
sudo /usr/bin/pmset -a disablesleep 0 || true

if [ -f "$DEST" ]; then
    echo "▸ Removing sudoers rule $DEST …"
    sudo rm -f "$DEST"
fi

if [ -d "$APP" ]; then
    echo "▸ Removing $APP …"
    rm -rf "$APP"
fi

echo "✓ Uninstalled. (A Login Item entry, if present, can be removed under"
echo "  System Settings → General → Login Items.)"
