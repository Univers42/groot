#!/usr/bin/env bash
# Installs/updates the native osionos desktop app (run with sudo):
#   sudo bash apps/osionos-desktop/install-app.sh
# Force-installs the freshly built .deb even if the version is unchanged
# (apt skips same-version upgrades; dpkg -i installs the exact file).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEB="$(ls -t "$DIR"/src-tauri/target/release/bundle/deb/osionos_*_amd64.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { echo "No .deb found — build it first: bash apps/osionos-desktop/build.sh"; exit 1; }
echo "Installing: $DEB"
dpkg -i "$DEB" || apt install -y -f   # -f resolves runtime libs on first install
echo "Done. Search 'osionos' in your application menu (close & reopen it if it was running)."
