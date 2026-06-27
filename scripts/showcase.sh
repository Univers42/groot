#!/usr/bin/env sh
# showcase.sh — recap every local URL the RUNNING stack exposes, click to open.
# Only services whose container is actually up are listed (no dead links). Printed
# at the very end of `make all`.
set -u

up()   { docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "$1"; }
# link <label> <container-regex> <url> — print only if the backing container is up.
link() { if up "$2"; then printf '    \033[32m●\033[0m %-16s \033[4;36m%s\033[0m\n' "$1" "$3"; fi; }

printf '\n  \033[1m══════════════════════════════════════════════\033[0m\n'
printf '  \033[1m  ✓  ft_transcendence is up — click to open\033[0m\n'
printf '  \033[1m══════════════════════════════════════════════\033[0m\n'
printf '\n  \033[1mApps\033[0m\n'
link 'Website'         'opposite-osiris-web'    'https://localhost:4322'
link 'osionos editor'  '[-_]osionos-app'        'https://localhost:3001'
link 'Mail'            '[-_]mail-[0-9]'          'https://localhost:3002'
link 'Calendar'        '[-_]calendar-[0-9]'      'https://localhost:3003'
printf '\n  \033[1mAPIs & infra\033[0m\n'
link 'osionos bridge'  'osionos-bridge'         'https://localhost:4000'
link 'Auth gateway'    'auth-gateway'           'https://localhost:8787/api/auth'
link 'grobase BaaS'    'mini-baas-kong'         'http://127.0.0.1:8000'
link 'LiveKit'         '[-_]livekit'            'ws://127.0.0.1:7880'
link 'Mailpit inbox'   'mini-baas-mailpit'      'http://localhost:8025'
link 'Grafana'         'mini-baas-grafana'      'http://localhost:3010'
printf '\n  \033[2mLogin\033[0m  dev.pro.photo / Osionos123!\n'
if [ -n "${SSH_CONNECTION:-}${VSCODE_IPC_HOOK_CLI:-}" ]; then
	printf '  \033[2m(remote/forwarded session: an auto-opened https://localhost:<port> may run outside this VM)\033[0m\n'
fi
printf '\n'
