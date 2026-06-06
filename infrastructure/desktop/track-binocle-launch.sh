#!/usr/bin/env bash
# ===========================================================================
# Track Binocle — desktop launcher (v0 of the all-in-one orchestrator app).
#
# One click -> the WHOLE local suite comes up (osionos + Mail + Calendar +
# lean BaaS) via Docker Compose -> the osionos editor opens. osionos is the
# orchestrator: its sidebar opens Mail and Calendar.
#
# HTTPS is preserved: the stack serves https://localhost:* through the local
# TLS proxy (the web/server distribution stays HTTPS by design). A native
# Tauri build (embedded webview, HTTP-loopback, .AppImage/.deb) is the next
# step — this launcher proves the all-in-one experience on your machine today.
#
# Usage:
#   track-binocle-launch.sh            # boot the suite + open osionos
#   track-binocle-launch.sh --install  # add a "Track Binocle" app icon
#   track-binocle-launch.sh --stop     # stop the suite
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OSIONOS_URL="https://localhost:${OSIONOS_HOST_PORT:-3001}"
DESKTOP_ID="track-binocle"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "Track Binocle" "$1" || echo "[track-binocle] $1"; }

install_desktop_entry() {
	local apps_dir="$HOME/.local/share/applications"
	local icon_dir="$HOME/.local/share/icons"
	local icon_src="$REPO/wiki/assets/header_hellish.png"
	mkdir -p "$apps_dir" "$icon_dir"
	local icon_line="Icon=utilities-terminal"
	if [ -f "$icon_src" ]; then cp -f "$icon_src" "$icon_dir/track-binocle.png"; icon_line="Icon=$icon_dir/track-binocle.png"; fi
	cat > "$apps_dir/$DESKTOP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Track Binocle
Comment=Open the osionos suite (osionos + Mail + Calendar + BaaS) running locally
Exec=$SCRIPT_DIR/track-binocle-launch.sh
$icon_line
Terminal=false
Categories=Office;Development;Network;
StartupNotify=true
EOF
	update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
	echo "Installed desktop entry: $apps_dir/$DESKTOP_ID.desktop"
	echo "You can now launch 'Track Binocle' from your application menu."
}

stop_stack() {
	cd "$REPO"
	docker compose --profile dev down
	notify "Suite stopped."
}

start_stack() {
	cd "$REPO"
	command -v docker >/dev/null 2>&1 || { notify "Docker is required but not installed."; exit 1; }
	# Offline secret generation if this machine was never bootstrapped.
	[ -f apps/baas/.env.local ] || make bootstrap
	notify "Starting the suite (osionos + Mail + Calendar + BaaS)..."
	docker compose --profile dev up -d
	# Best-effort readiness wait (~90s) on the osionos editor.
	for _ in $(seq 1 45); do
		curl -sk -o /dev/null "$OSIONOS_URL" 2>/dev/null && break
		sleep 2
	done
}

open_app() {
	if command -v xdg-open >/dev/null 2>&1; then xdg-open "$OSIONOS_URL" >/dev/null 2>&1 || true
	else echo "[track-binocle] Open: $OSIONOS_URL"; fi
}

case "${1:-launch}" in
	--install) install_desktop_entry ;;
	--stop|stop) stop_stack ;;
	launch|"") start_stack; notify "Suite ready — opening osionos"; open_app ;;
	*) echo "usage: $0 [--install|launch|--stop]"; exit 1 ;;
esac
