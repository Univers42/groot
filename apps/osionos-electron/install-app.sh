#!/usr/bin/env bash
# Install the latest built osionos Electron .deb (force-install so same-version
# rebuilds always replace the previous one). Run with sudo.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEB="$(ls -t "$REPO"/apps/osionos-electron/dist/osionos_*.deb 2>/dev/null | head -1)"
[ -n "${DEB:-}" ] || { echo "No .deb found — run: bash apps/osionos-electron/build.sh"; exit 1; }
echo "Installing $DEB …"
dpkg -i "$DEB" || apt-get install -y -f
echo "Installed. Launch 'osionos' from your app menu, or run: osionos"
