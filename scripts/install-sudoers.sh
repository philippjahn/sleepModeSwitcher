#!/usr/bin/env bash
# Installs a narrowly-scoped NOPASSWD sudoers rule so SleepModeSwitcher can run
# the two pmset commands without a password prompt on every click.
#
# The rule grants passwordless sudo for EXACTLY these two commands and nothing
# else, so the security exposure is minimal.
set -euo pipefail

USER_NAME="$(id -un)"
DEST="/etc/sudoers.d/sleepmodeswitcher"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF

echo "▸ Validating sudoers syntax …"
if ! sudo visudo -c -f "$TMP" >/dev/null; then
    echo "✗ Invalid sudoers syntax – nothing was installed." >&2
    exit 1
fi

echo "▸ Installing to $DEST (sudo password required once) …"
sudo install -m 0440 -o root -g wheel "$TMP" "$DEST"

echo "✓ Done. Verify with:  sudo -l | grep pmset"
