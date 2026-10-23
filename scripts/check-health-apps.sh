#!/usr/bin/env sh
# check-health-apps.sh — app health matrix: localhost dev stack + production (Vercel
# sites + fly backend). Driven by `make check_health_apps`. For every app it probes the
# local URL and the production URL, then prints a status matrix so you can see at a glance
# what is up, what is down, and click straight to whichever you want to open.
#
# Production URLs are overridable via env (PROD_WEBSITE_URL / PROD_OSIONOS_URL /
# PROD_GROBASE_URL / PROD_AUTH_URL); HEALTH_TIMEOUT (default 6s) bounds each probe.
#
# The localhost rows follow the host ports scripts/host-ports.sh chose: the NAME variables
# come from the environment (make exports them) or from .env.ports, and the literal is only
# the fallback for a stack that never resolved them. Kong's own 127.0.0.1:8000 is fixed by
# grobase, not by us, so it stays a literal.
set -u

TIMEOUT="${HEALTH_TIMEOUT:-6}"
PROD_WEBSITE="${PROD_WEBSITE_URL:-https://prismatica-eta.vercel.app}"
PROD_OSIONOS="${PROD_OSIONOS_URL:-https://osionos.vercel.app}"
PROD_GROBASE="${PROD_GROBASE_URL:-https://grobase-stack.fly.dev}"
PROD_AUTH="${PROD_AUTH_URL:-https://prismatica-auth-gateway.fly.dev}"

# The chosen host ports, when this shell was not started by make. The environment wins: a
# port pinned for one run stays pinned.
PORTS_FILE="${HOST_PORTS_FILE:-$(cd "$(dirname "$0")/.." && pwd)/.env.ports}"
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

# probe URL -> HTTP status code (000 = unreachable). -k accepts the local self-signed cert.
probe() {
	[ -n "$1" ] || { printf '%s' '---'; return; }
	code=$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$1" 2>/dev/null) || code=000
	# Same rule as docker-compose.yml's auth-gateway healthcheck: older gateways only serve /availability.
	if [ "$code" = 404 ] && [ "${1%/api/auth/health}" != "$1" ]; then
		probe "${1%/health}/availability"
		return
	fi
	printf '%s' "$code"
}

# up_code CODE -> 0 if the server is responding (any HTTP reply, incl. auth-gated 401/403).
up_code() {
	case "$1" in 2[0-9][0-9] | 30[0-9] | 401 | 403) return 0 ;; *) return 1 ;; esac
}

# sfield CODE -> 7-wide colored status cell (ASCII for exact column alignment).
sfield() {
	case "$1" in
	---) printf '\033[2m%-7s\033[0m' 'n/a' ;;
	2[0-9][0-9] | 30[0-9] | 401 | 403) printf '\033[1;32m%-7s\033[0m' 'UP' ;;
	000) printf '\033[1;31m%-7s\033[0m' 'DOWN' ;;
	*) printf '\033[1;33m%-7s\033[0m' "$1" ;;
	esac
}

printf '\n  \033[1mApp health matrix\033[0m  \033[2m(localhost dev stack   •   production: Vercel + fly)\033[0m\n\n'
printf '  \033[1m%-16s %-24s %-7s %-41s %-7s\033[0m\n' 'APP' 'LOCALHOST' 'LOCAL' 'PRODUCTION (Vercel / fly)' 'PROD'
printf '  \033[2m%s\033[0m\n' '──────────────────────────────────────────────────────────────────────────────────────────────'

LUP=0
LT=0
PUP=0
PT=0
while IFS='|' read -r name ldisp lprobe pdisp pprobe; do
	[ -n "$name" ] || continue
	lc="$(probe "$lprobe")"
	pc="$(probe "$pprobe")"
	printf '  %-16s %-24s ' "$name" "$ldisp"
	sfield "$lc"
	printf ' %-41s ' "${pdisp:-(local only)}"
	sfield "$pc"
	printf '\n'
	LT=$((LT + 1))
	up_code "$lc" && LUP=$((LUP + 1))
	if [ -n "$pprobe" ]; then
		PT=$((PT + 1))
		up_code "$pc" && PUP=$((PUP + 1))
	fi
done <<EOF
opposite-osiris|https://localhost:${OPPOSITE_OSIRIS_HOST_PORT:-4322}|https://localhost:${OPPOSITE_OSIRIS_HOST_PORT:-4322}|$PROD_WEBSITE|$PROD_WEBSITE
osionos|https://localhost:${OSIONOS_APP_HOST_PORT:-3001}|https://localhost:${OSIONOS_APP_HOST_PORT:-3001}|$PROD_OSIONOS|$PROD_OSIONOS
osionos-bridge|https://localhost:${OSIONOS_BRIDGE_HOST_PORT:-4000}|https://localhost:${OSIONOS_BRIDGE_HOST_PORT:-4000}/api/auth/bridge/health|$PROD_GROBASE|$PROD_GROBASE/api/auth/bridge/health
auth-gateway|https://localhost:${AUTH_GATEWAY_HOST_PORT:-8787}|https://localhost:${AUTH_GATEWAY_HOST_PORT:-8787}/api/auth/health|$PROD_AUTH|$PROD_AUTH/api/auth/health
grobase (Kong)|http://127.0.0.1:8000|http://127.0.0.1:8000/auth/v1/health|$PROD_GROBASE|$PROD_GROBASE/auth/v1/health
grobase (TLS)|https://localhost:${GROBASE_TLS_HOST_PORT:-8444}|https://localhost:${GROBASE_TLS_HOST_PORT:-8444}/auth/v1/health||
mail|https://localhost:${MAIL_HOST_PORT:-3002}|https://localhost:${MAIL_HOST_PORT:-3002}||
calendar|https://localhost:${CALENDAR_HOST_PORT:-3003}|https://localhost:${CALENDAR_HOST_PORT:-3003}||
EOF

printf '\n  \033[2msummary:\033[0m  localhost \033[1m%s/%s\033[0m up    •    production \033[1m%s/%s\033[0m up\n' "$LUP" "$LT" "$PUP" "$PT"
printf '  \033[2m(UP = server responded; auth-gated 401/403 counts as up. login: dev.pro.photo@gmail.com, password: make demo-login)\033[0m\n\n'
