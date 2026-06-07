#!/usr/bin/env bash
# Install the latest built osionos Electron .deb (force-install so same-version
# rebuilds always replace the previous one). Run with sudo.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEB="$(ls -t "$REPO"/apps/osionos-electron/dist/osionos*.deb 2>/dev/null | head -1)"
[ -n "${DEB:-}" ] || { echo "No .deb found — run: bash apps/osionos-electron/build.sh"; exit 1; }

# Remove the older Tauri build if present — it installs as package 'osionos'
# (binary /usr/bin/app, osionos.desktop) and would keep shadowing the menu entry,
# so you'd keep launching Tauri instead of this Electron build.
if dpkg -s osionos >/dev/null 2>&1; then
  echo "Removing the old Tauri osionos so the menu launches the Electron build…"
  apt-get remove -y osionos 2>/dev/null || dpkg -r osionos || true
fi

echo "Installing $DEB …"
# --force-depends covers Ubuntu 24.04's GTK package rename (libgtk-3-0 ->
# libgtk-3-0t64): GTK is installed, only the dependency *name* differs.
dpkg -i "$DEB" || apt-get install -y -f || dpkg -i --force-depends "$DEB"

# Electron's sandbox helper must be setuid root. On Ubuntu 24.04 unprivileged
# user namespaces are restricted (kernel.apparmor_restrict_unprivileged_userns=1),
# so without this the app silently fails to launch.
for sb in /opt/osionos/chrome-sandbox; do
  [ -f "$sb" ] && { chown root:root "$sb" && chmod 4755 "$sb" && echo "Set $sb setuid root."; }
done

echo "Installed. Launch 'osionos' from your app menu (or run: osionos-desktop)."
