# Shared stubs and helpers for the public-funnel bats suites: tailscale, docker and curl on PATH
# keep their state in files under $T. Loaded with `load public-funnel-helpers`.
SCRIPT="$BATS_TEST_DIRNAME/../public-funnel.sh"
SECRETS="jwt-AAAA-1111 svc-BBBB-2222 baas-CCCC-3333 rt-DDDD-4444 sess-EEEE-5555 bridge-FFFF-6666 linkkey-GGGG-7777-0123456789abcdef"

stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

make_stubs() {
  stub tailscale 'sock=$2
shift 2
case "$sock" in
*/tailscale-*) who=apps; f="$T/funnel-apps"; dns="${TSA_DNS:-osionos-apps.tail10f2ea.ts.net.}"; pre="[apps] "; [ -f "$T/apps-node" ] || exit 1 ;;
*) who=main; f="$T/funnel"; dns="${TS_DNS:-osionos.tail10f2ea.ts.net.}"; pre="" ;;
esac
if [ "$who" = main ] && [ -n "${TS_DOWN:-}" ]; then exit 1; fi
echo "$pre$*" >>"$T/ts.log"
case "$1 $2" in
"status --json") printf "{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"%s\"}}\n" "$dns" ;;
"funnel status")
  host="${dns%.}"; allow=""; web=""
  while read -r p l; do
    [ -n "$p" ] || continue
    if [ -z "$l" ]; then case "$p" in 443) l=4322 ;; 8443) l=3001 ;; *) l=4000 ;; esac; fi
    allow="$allow${allow:+,}\"$host:$p\":true"
    web="$web${web:+,}\"$host:$p\":{\"Handlers\":{\"/\":{\"Proxy\":\"https+insecure://127.0.0.1:$l\"}}}"
  done <"$f"
  printf "{\"AllowFunnel\":{%s},\"Web\":{%s}}\n" "$allow" "$web" ;;
"funnel reset") : >"$f" ;;
"funnel --bg") echo "${3#--https=} ${4##*:}" >>"$f" ;;
esac'
  stub docker 'echo "$*" >>"$T/docker.log"
case "$1" in
ps) case "$*" in
  *--format*) cat "$T/ps-services" ;;
  *service=osionos-bridge*) echo cid-bridge ;;
  *service=auth-gateway*) echo cid-gw ;;
  *service=mail-web*) if [ -f "$T/env-mail" ]; then echo cid-mail; fi ;;
  *service=calendar-web*) if [ -f "$T/env-cal" ]; then echo cid-cal; fi ;;
  *service=osionos-ide-server*) [ -f "$T/env-ide" ] && echo cid-ide ;;
  esac ;;
image) exit "${IMG_RC:-0}" ;;
inspect) f="$T/env-${4#cid-}"; case "$3" in *Config.Env*) [ -z "${ENV_FAIL:-}" ] && cat "$f" ;; *ReadonlyRootfs*) cat "$T/shape-${4#cid-}" ;; esac ;;
exec) f="$T/env-${2#cid-}"; if [ "$3" = env ]; then cat "$f"; else grep "^$4=" "$f" 2>/dev/null | cut -d= -f2- | grep .; fi ;;
logs) cat "$T/gw.log" ;;
run) case "$*" in
  *"find /usr/share"*) echo "${FILES:-3}" ;;
  *"-e V1"*) case "$V1" in *:8443*) echo "${CAL_HITS:-1}" ;; *) echo "${MAIL_HITS:-1}" ;; esac ;;
  *localhost*) printf "%s\n" "${LINK_OUT-0}" ;;
  *osionos-mail-web*) echo "${MAIL_BUNDLE_HITS:-0}" ;;
  *osionos-calendar-web*) echo "${CAL_BUNDLE_HITS:-0}" ;;
  *) echo "${RUN_HITS:-0}" ;;
  esac ;;
esac'
  stub curl 'case "$*" in
*"-x socks5h://"*) echo "$*" >>"$T/tls.log"; exit "${TLS_RC:-0}" ;;
*127.0.0.1:310[23]*)
  for last; do :; done
  case "$*" in
  *"-w "*) case "$last" in *"${NODEV_LEAK:-//none}"*) echo 200 ;; *) echo "${NODEV_CODE:-404}" ;; esac ;;
  *) case "$last" in *:3102*) cat "$T/hdr-3102" ;; *) cat "$T/hdr-3103" ;; esac ;;
  esac ;;
*"-X POST"*) echo "${EDGE_STREAM:-404}" ;;
*) n=${GEO_503:-14}; i=0; while [ $i -lt 20 ]; do [ $i -lt $((20 - n)) ] && echo 502 || echo 503; i=$((i + 1)); done ;;
esac'
}

setup() {
  T="$BATS_TEST_TMPDIR"
  BIN="$T/bin"
  mkdir -p "$BIN" "$T/repo"
  export T PATH="$BIN:$PATH" PUBLIC_REPO="$T/repo" TAILSCALE_BIN="$BIN/tailscale" TAILSCALE_SOCKET="$T/sock" XDG_STATE_HOME="$T/state"
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
PUBLIC_MAIL_ORIGIN=https://osionos-apps.tail10f2ea.ts.net
PUBLIC_CALENDAR_ORIGIN=https://osionos-apps.tail10f2ea.ts.net:8443
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
  setup_apps
}

# The apps node runs and serves Mail and Calendar; both static containers hold clean envs and
# answer with the MC4 headers (one file per loopback port).
setup_apps() {
  touch "$T/apps-node"
  printf '443 3102\n8443 3103\n' >"$T/funnel-apps"
  printf 'osionos-bridge\nauth-gateway\nmail-web\ncalendar-web\n' >"$T/ps-services"
  printf 'PATH=/usr/bin\nNGINX_VERSION=1.27\nHOSTNAME=abc\n' >"$T/env-mail"
  cp "$T/env-mail" "$T/env-cal"
  printf 'ro=true mem=67108864 nets=track-binocle_apps-static-net, mounts=\n' >"$T/shape-mail"
  cp "$T/shape-mail" "$T/shape-cal"
  printf 'HTTP/2 200\r\ncontent-security-policy: default-src %s; script-src %s; connect-src %s; style-src %s; base-uri %s; frame-ancestors https://osionos.tail10f2ea.ts.net:8443\r\nx-content-type-options: nosniff\r\nreferrer-policy: no-referrer\r\nstrict-transport-security: max-age=31536000\r\n\r\n' "'self'" "'self'" "'self'" "'self'" "'none'" >"$T/hdr-3102"
  cp "$T/hdr-3102" "$T/hdr-3103"
}

run_pf() { run "$SCRIPT" "$@"; out="$output"; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
lacks() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then
    echo "unexpected in output: $1" >&2
    return 1
  fi
}
funnel_calls() { grep -c -- '^funnel --bg --https=' "$T/ts.log" || true; }
apps_funnel_calls() { grep -c -- '^\[apps\] funnel --bg --https=' "$T/ts.log" || true; }
set_env() { sed -i "s|^$1=.*|$1=$2|" "$T/repo/.env.public"; }
