# Shared stubs and helpers for the public-funnel bats suites: tailscale, docker and curl on PATH
# keep their state in files under $T. Loaded with `load public-funnel-helpers`.
SCRIPT="$BATS_TEST_DIRNAME/../public-funnel.sh"
SECRETS="jwt-AAAA-1111 svc-BBBB-2222 baas-CCCC-3333 rt-DDDD-4444 sess-EEEE-5555 bridge-FFFF-6666 linkkey-GGGG-7777-0123456789abcdef"

stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

make_stubs() {
  stub tailscale 'shift 2
echo "$*" >>"$T/ts.log"
case "$1 $2" in
"status --json") printf "{\"Self\":{\"DNSName\":\"%s\"}}\n" "${TS_DNS:-osionos.tail10f2ea.ts.net.}" ;;
"funnel status")
  printf "{\"AllowFunnel\":{"; sep=""
  for p in $(cat "$T/funnel" 2>/dev/null); do printf "%s\"osionos.tail10f2ea.ts.net:%s\":true" "$sep" "$p"; sep=","; done
  printf "}}\n" ;;
"funnel reset") : >"$T/funnel" ;;
"funnel --bg") echo "${3#--https=}" >>"$T/funnel" ;;
esac'
  stub docker 'echo "$*" >>"$T/docker.log"
case "$1" in
ps) case "$*" in *service=osionos-bridge*) echo cid-bridge ;; *service=auth-gateway*) echo cid-gw ;; *service=osionos-ide-server*) [ -f "$T/env-ide" ] && echo cid-ide ;; esac ;;
exec) f="$T/env-${2#cid-}"; grep "^$4=" "$f" 2>/dev/null | cut -d= -f2- | grep . ;;
logs) cat "$T/gw.log" ;;
run) case "$*" in *localhost*) printf "%s\n" "${LINK_OUT-0}" ;; *) echo "${RUN_HITS:-0}" ;; esac ;;
esac'
  stub curl 'case "$*" in
*"-x socks5h://"*) echo "$*" >>"$T/tls.log"; exit "${TLS_RC:-0}" ;;
*"-X POST"*) echo "${EDGE_STREAM:-404}" ;;
*) n=${GEO_503:-14}; i=0; while [ $i -lt 20 ]; do [ $i -lt $((20 - n)) ] && echo 502 || echo 503; i=$((i + 1)); done ;;
esac'
}

setup() {
  T="$BATS_TEST_TMPDIR"
  BIN="$T/bin"
  mkdir -p "$BIN" "$T/repo"
  export T PATH="$BIN:$PATH" PUBLIC_REPO="$T/repo" TAILSCALE_BIN="$BIN/tailscale" TAILSCALE_SOCKET="$T/sock"
  make_stubs
  git -C "$T/repo" init -q
  echo ".env.public" >"$T/repo/.gitignore"
  cp "$BATS_TEST_DIRNAME/../../.env.public.example" "$T/repo/.env.public.example"
  cat >"$T/repo/.env.public" <<ENV
PUBLIC_ORIGIN=https://osionos.tail10f2ea.ts.net
AUTH_LINK_SIGNING_KEY=linkkey-GGGG-7777-0123456789abcdef
OSIONOS_ADMIN_EMAILS=admin@example.test
AUTH_MAIL_DAILY_CAP=50
AUTH_TRUSTED_PROXY_HOPS=3
AUTH_SIGNUP_OPEN=true
AUTH_REGISTER_RATE_LIMIT_PER_HOUR=10
ENV
  chmod 600 "$T/repo/.env.public"
  cat >"$T/repo/.env.local" <<ENV
JWT_SECRET=jwt-AAAA-1111
SERVICE_ROLE_KEY=svc-BBBB-2222
OSIONOS_BAAS_API_KEY=baas-CCCC-3333
VITE_BAAS_REALTIME_TOKEN=rt-DDDD-4444
OSIONOS_APP_SESSION_SECRET=sess-EEEE-5555
OSIONOS_BRIDGE_SHARED_SECRET=bridge-FFFF-6666
ENV
  printf 'OSIONOS_ADMIN_EMAILS=admin@example.test\nOSIONOS_ALLOWED_ORIGIN=https://osionos.tail10f2ea.ts.net:8443\n' >"$T/env-bridge"
  printf 'AUTH_DEMO_INSECURE=false\nTURNSTILE_BYPASS_LOCAL=false\nAUTH_REQUIRE_EMAIL_VERIFICATION=true\n' >"$T/env-gw"
  printf '%s\n' 'Auth gateway listening on http://localhost:8787/api/auth and /api/newsletter (rate-limit store: memory, trusted proxy hops: 3)' '[auth-gateway] connected to Redis for shared rate-limit/lockout state.' >"$T/gw.log"
  : >"$T/funnel"
  : >"$T/ts.log"
}

run_pf() { run "$SCRIPT" "$@"; out="$output"; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
lacks() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then
    echo "unexpected in output: $1" >&2
    return 1
  fi
}
funnel_calls() { grep -c -- '--https=' "$T/ts.log" || true; }
set_env() { sed -i "s|^$1=.*|$1=$2|" "$T/repo/.env.public"; }
