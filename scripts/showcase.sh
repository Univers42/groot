#!/usr/bin/env sh
# showcase.sh — recap every local URL the RUNNING stack exposes, click to open.
# Only services whose container is actually up are listed (no dead links). Printed
# at the very end of `make all`.
#
# The URLs follow the host ports scripts/host-ports.sh chose: the NAME variables come from
# the environment (make exports them) or from .env.ports, and the literal is only the
# fallback for a stack that never resolved them. Kong's own 127.0.0.1:8000 is grobase's,
# not ours, so it stays a literal.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/demo-login.sh
. "$REPO/scripts/lib/demo-login.sh"
rc=0

# The chosen host ports, when this shell was not started by make. The environment wins: a
# port pinned for one run stays pinned.
PORTS_FILE="${HOST_PORTS_FILE:-$REPO/.env.ports}"
if [ -f "$PORTS_FILE" ]; then
  while IFS='=' read -r pk pv; do
    case "$pk" in
    '' | '#'*) continue ;;
    esac
    printf '%s' "$pk" | grep -qE '^[A-Z_][A-Z0-9_]*_HOST_PORT$' || continue
    case "$pv" in
    '' | *[!0-9]*) continue ;;
    esac
    eval "pv=\${$pk:-}"
    [ -n "$pv" ] && continue
    eval "$pk=\$pv"
  done <"$PORTS_FILE"
fi

up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "$1"; }
# link <label> <container-regex> <url> — print only if the backing container is up.
link() { if up "$2"; then printf '    \033[32m●\033[0m %-16s \033[4;36m%s\033[0m\n' "$1" "$3"; fi; }
# hostport <container> <container-port> <fallback> — the host port docker ACTUALLY published.
# grobase's resolve-ports.sh moves a service to the next free port when its default is taken
# (an old stack still shutting down is enough), so a hardcoded port here prints a link to
# something nothing is listening on. Measured: kong 8000->8001 and mailpit 8025->8026 in the
# same run, both printed as the default.
hostport() {
	p=$(docker port "$1" "$2/tcp" 2>/dev/null | head -1 | sed 's/.*://')
	printf '%s' "${p:-$3}"
}

printf '\n  \033[1m══════════════════════════════════════════════\033[0m\n'
printf '  \033[1m  ✓  ft_transcendence is up — click to open\033[0m\n'
printf '  \033[1m══════════════════════════════════════════════\033[0m\n'
printf '\n  \033[1mApps\033[0m\n'
link 'Website' 'opposite-osiris-web' "https://localhost:${OPPOSITE_OSIRIS_HOST_PORT:-4322}"
link 'osionos editor' '[-_]osionos-app' "https://localhost:${OSIONOS_APP_HOST_PORT:-3001}"
link 'Mail' '[-_]mail-[0-9]' "https://localhost:${MAIL_HOST_PORT:-3002}"
link 'Calendar' '[-_]calendar-[0-9]' "https://localhost:${CALENDAR_HOST_PORT:-3003}"
printf '\n  \033[1mAPIs & infra\033[0m\n'
link 'osionos bridge' 'osionos-bridge' "https://localhost:${OSIONOS_BRIDGE_HOST_PORT:-4000}"
link 'Auth gateway' 'auth-gateway' "https://localhost:${AUTH_GATEWAY_HOST_PORT:-8787}/api/auth"
link 'grobase BaaS' 'mini-baas-kong' "http://127.0.0.1:$(hostport mini-baas-kong 8000 8000)"
link 'LiveKit' '[-_]livekit' 'ws://127.0.0.1:7880'
link 'Mailpit inbox' 'mini-baas-mailpit' "http://localhost:$(hostport mini-baas-mailpit 8025 8025)"
link 'Grafana' 'mini-baas-grafana' "http://localhost:$(hostport mini-baas-grafana 3000 3010)"
# The demo password is minted per machine (never committed); a missing one is reported, not
# printed empty — the recap still lists every URL.
if pw="$(demo_login_password "$REPO/.env.local")"; then
  printf '\n  \033[2mLogin\033[0m  %s / %s\n' "$DEMO_LOGIN_EMAIL" "$pw"
else
  printf '\n  \033[2mLogin\033[0m  %s / \033[31m(DEMO_LOGIN_PASSWORD missing — see above)\033[0m\n' "$DEMO_LOGIN_EMAIL"
  rc=1
fi
if [ -n "${SSH_CONNECTION:-}${VSCODE_IPC_HOOK_CLI:-}" ]; then
  printf '  \033[2m(remote/forwarded session: an auto-opened https://localhost:<port> may run outside this VM)\033[0m\n'
fi
printf '\n'
exit "$rc"
