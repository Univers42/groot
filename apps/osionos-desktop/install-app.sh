#!/usr/bin/env bash
# Installs the native osionos desktop app + its runtime libs (run with sudo).
#   sudo bash apps/osionos-desktop/install-app.sh
set -e
DEB="/home/dlesieur/Documents/ft_transcendence/apps/osionos-desktop/src-tauri/target/release/bundle/deb/osionos_0.1.0_amd64.deb"
[ -f "$DEB" ] || { echo "Build it first: see apps/osionos-desktop/README.md"; exit 1; }
apt install -y "$DEB"
echo "Installed. Search 'osionos' in your application menu."
