#!/usr/bin/env sh
# check-health-apps.sh — app health matrix: localhost dev stack + production (Vercel
# sites + fly backend). Driven by `make check_health_apps`. For every app it probes the
# local URL and the production URL, then prints a status matrix so you can see at a glance
# what is up, what is down, and click straight to whichever you want to open.
#
# Production URLs are overridable via env (PROD_WEBSITE_URL / PROD_OSIONOS_URL /
# PROD_GROBASE_URL / PROD_AUTH_URL); HEALTH_TIMEOUT (default 6s) bounds each probe.
set -u

TIMEOUT="${HEALTH_TIMEOUT:-6}"
PROD_WEBSITE="${PROD_WEBSITE_URL:-https://prismatica-eta.vercel.app}"
PROD_OSIONOS="${PROD_OSIONOS_URL:-https://osionos.vercel.app}"
PROD_GROBASE="${PROD_GROBASE_URL:-https://grobase-stack.fly.dev}"
PROD_AUTH="${PROD_AUTH_URL:-https://prismatica-auth-gateway.fly.dev}"

# probe URL -> HTTP status code (000 = unreachable). -k accepts the local self-signed cert.
probe() {
	[ -n "$1" ] || { printf '%s' '---'; return; }
	curl -k -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$1" 2>/dev/null || printf '%s' '000'
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
opposite-osiris|https://localhost:4322|https://localhost:4322|$PROD_WEBSITE|$PROD_WEBSITE
osionos|https://localhost:3001|https://localhost:3001|$PROD_OSIONOS|$PROD_OSIONOS
osionos-bridge|https://localhost:4000|https://localhost:4000/api/auth/bridge/health|$PROD_GROBASE|$PROD_GROBASE/api/auth/bridge/health
auth-gateway|https://localhost:8787|https://localhost:8787/api/auth/availability|$PROD_AUTH|$PROD_AUTH/api/auth/availability
grobase (Kong)|http://127.0.0.1:8000|http://127.0.0.1:8000/auth/v1/health|$PROD_GROBASE|$PROD_GROBASE/auth/v1/health
mail|https://localhost:3002|https://localhost:3002||
calendar|https://localhost:3003|https://localhost:3003||
EOF

printf '\n  \033[2msummary:\033[0m  localhost \033[1m%s/%s\033[0m up    •    production \033[1m%s/%s\033[0m up\n' "$LUP" "$LT" "$PUP" "$PT"
printf '  \033[2m(UP = server responded; auth-gated 401/403 counts as up. login: dev.pro.photo / Osionos123!)\033[0m\n\n'
