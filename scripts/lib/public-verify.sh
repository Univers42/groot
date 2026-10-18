#!/usr/bin/env bash
# public-verify.sh — the checks behind `public-funnel.sh verify`, one function per check, each
# printing exactly one PASS/FAIL/SKIP line per fact. A SKIP is a check that could not run and is
# never counted as a pass; any FAIL makes run_verify return 1. Sourced by scripts/public-funnel.sh,
# which provides ts, penv, svc_container, ENV_FILE, REPO and the PUBLIC_* settings.
# No check prints a secret value: only key names, file names and counts.
#
# Caveat: these are probes of what is running NOW, not proofs. The bundle grep misses a secret
# that is split, encoded or minified into escapes; the env checks read the containers, not the
# image they were built from; the geocode probe is rate-based (see check_edge).

V_PASS=0 V_FAIL=0 V_SKIP=0

pass() { V_PASS=$((V_PASS + 1)); printf 'PASS  %-14s %s\n' "$1" "$2"; }
fail() { V_FAIL=$((V_FAIL + 1)); printf 'FAIL  %-14s %s\n' "$1" "$2"; }
skip() { V_SKIP=$((V_SKIP + 1)); printf 'SKIP  %-14s %s\n' "$1" "$2"; }
# expect NAME PASS-MESSAGE FAIL-MESSAGE COMMAND...: one line, PASS when COMMAND succeeds.
expect() {
  local name=$1 ok=$2 ko=$3
  shift 3
  if "$@"; then pass "$name" "$ok"; else fail "$name" "$ko"; fi
}

# The secrets that must never be inside a served bundle, and where their values may live.
BUNDLE_SECRET_KEYS="JWT_SECRET SERVICE_ROLE_KEY OSIONOS_BAAS_API_KEY VITE_BAAS_REALTIME_TOKEN OSIONOS_APP_SESSION_SECRET OSIONOS_BRIDGE_SHARED_SECRET AUTH_LINK_SIGNING_KEY"
BRIDGE_MUST_BE_EMPTY="OSIONOS_AGENT_CLAUDE OSIONOS_IDE_ALLOWED_SUBJECTS OSIONOS_RUNNER_URL OSIONOS_SQL_RO OSIONOS_IDE_TOKEN_SECRET"

# shellcheck source=scripts/lib/public-verify-surfaces.sh
. "$(dirname "${BASH_SOURCE[0]}")/public-verify-surfaces.sh"

# host part of PUBLIC_ORIGIN (https://host, no port, no path).
origin_host() {
  local o
  o=$(penv PUBLIC_ORIGIN || true)
  o=${o#https://}
  printf '%s' "${o%%[:/]*}"
}

is_int_between() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

# Open Funnel ports, comma-joined ascending; fails when tailscale cannot answer.
# Caveat: reads .AllowFunnel from `funnel status --json` (tailscale 1.104); another schema
# reads as "nothing open", which the explicit-scope form of verify turns into a FAIL.
funnel_ports() {
  local json
  json=$(ts funnel status --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '(.AllowFunnel // {}) | to_entries[] | select(.value == true) | .key | split(":") | last' |
    sort -n | paste -sd, -
}

check_node_name() {
  local host have
  host=$(origin_host)
  [ -n "$host" ] || { fail node-name "PUBLIC_ORIGIN is not an https://host origin in .env.public"; return; }
  have=$(ts status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)
  if [ "$have" = "$host." ]; then pass node-name "this node is $have"
  else fail node-name "node DNS name is '${have:-unreadable}', PUBLIC_ORIGIN wants '$host.'"; fi
}

# $1: 443 | all | empty (either known set is accepted; an empty set is then a SKIP).
check_exposure() {
  local have want
  have=$(funnel_ports) || { fail exposure "cannot read the funnel status"; return; }
  case "$1" in
    443) want=443 ;;
    all) want=443,8443,10000 ;;
    *) want="" ;;
  esac
  if [ -n "$want" ]; then
    expect exposure "funnel ports: $have" "funnel ports '${have:-none}', expected exactly $want" [ "$have" = "$want" ]
  elif [ -z "$have" ]; then skip exposure "funnel closed: nothing is exposed"
  elif [ "$have" = 443 ] || [ "$have" = 443,8443,10000 ]; then pass exposure "funnel ports: $have"
  else fail exposure "funnel ports '$have', expected 443 alone or 443,8443,10000"; fi
}

# Count of files in IMAGE holding the value of the exported V; docker reads V from our env,
# so the value is on no command line.
bundle_hits() {
  docker run --rm -e V --entrypoint sh "$1" -c 'grep -rlF -- "$V" /usr/share/nginx/html /app /srv 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]'
}

# A secret value from one env file, scanned in both public images.
scan_secret() {
  local key=$1 file=$2 value=$3 image hits bad=0
  for image in "$APP_IMAGE" "$WEB_IMAGE"; do
    hits=$(V="$value" bundle_hits "$image" || true)
    if [ "$hits" = 0 ]; then continue; fi
    bad=1
    if [ -n "$hits" ]; then fail bundle-secret "$key (from ${file##*/}) found in $hits file(s) of $image"
    else fail bundle-secret "$key (from ${file##*/}) could not be scanned in $image"; fi
  done
  [ "$bad" = 1 ] || pass bundle-secret "$key (from ${file##*/}): 0 files in $APP_IMAGE and $WEB_IMAGE"
}

check_bundle_secrets() {
  local key file value seen=$'\n' found
  for key in $BUNDLE_SECRET_KEYS; do
    found=0
    for file in "$LOCAL_ENV" "$REMOTE_ENV" "$ENV_FILE"; do
      value=$(get_env "$file" "$key" || true)
      [ -n "$value" ] || continue
      case "$seen" in *$'\n'"$key=$value"$'\n'*) continue ;; esac
      seen+="$key=$value"$'\n'
      found=1
      scan_secret "$key" "$file" "$value"
    done
    [ "$found" = 1 ] || skip bundle-secret "$key is unset in every env file: nothing to look for"
  done
}

container_env() { docker exec "$1" printenv "$2" 2>/dev/null || true; }

check_bridge_env() {
  local c key have want
  c=$(svc_container osionos-bridge)
  [ -n "$c" ] || { fail bridge-env "osionos-bridge is not running"; return; }
  for key in $BRIDGE_MUST_BE_EMPTY; do
    expect bridge-env "$key is empty" "$key is set (value withheld)" [ -z "$(container_env "$c" "$key")" ]
  done
  want=$(penv OSIONOS_ADMIN_EMAILS || true)
  have=$(container_env "$c" OSIONOS_ADMIN_EMAILS)
  if [ -n "$want" ] && [ "$have" = "$want" ]; then pass bridge-env "OSIONOS_ADMIN_EMAILS equals .env.public"
  else fail bridge-env "OSIONOS_ADMIN_EMAILS differs from .env.public (or is empty there)"; fi
  want="$(penv PUBLIC_ORIGIN || true):8443"
  expect bridge-env "OSIONOS_ALLOWED_ORIGIN is the app origin" "OSIONOS_ALLOWED_ORIGIN is not $want" [ "$(container_env "$c" OSIONOS_ALLOWED_ORIGIN)" = "$want" ]
}

# Lower-cased, trimmed entries of a comma list, one per line.
list_entries() { printf '%s' "$1" | tr 'A-Z,' 'a-z\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . || true; }

# Entries of $1 that also appear in $2 (comma lists), one per line.
list_overlap() {
  local a b
  a=$(list_entries "$1")
  b=$(list_entries "$2")
  if [ -n "$a" ] && [ -n "$b" ]; then grep -Fxf <(printf '%s\n' "$b") <<<"$a" || true; fi
}

# An address list, not a secret: printed as a value. An exempt account is never mailed, so an
# admin among them would be an unverified admin.
check_verification_exempt() {
  local exempt overlap
  exempt=$(container_env "$1" AUTH_VERIFICATION_EXEMPT)
  overlap=$(list_overlap "$exempt" "$(penv OSIONOS_ADMIN_EMAILS || true)" | paste -sd, -)
  expect gateway-env "AUTH_VERIFICATION_EXEMPT=${exempt:-<empty>}" "AUTH_VERIFICATION_EXEMPT=${exempt:-<empty>} lists an OSIONOS_ADMIN_EMAILS admin: $overlap" [ -z "$overlap" ]
}

check_gateway_env() {
  local c hops logs
  c=$(svc_container auth-gateway)
  [ -n "$c" ] || { fail gateway-env "auth-gateway is not running"; return; }
  expect gateway-env "AUTH_DEMO_INSECURE is not true" "AUTH_DEMO_INSECURE is true" [ "$(container_env "$c" AUTH_DEMO_INSECURE)" != true ]
  expect gateway-env "TURNSTILE_BYPASS_LOCAL=false" "TURNSTILE_BYPASS_LOCAL is not false" [ "$(container_env "$c" TURNSTILE_BYPASS_LOCAL)" = false ]
  expect gateway-env "AUTH_REQUIRE_EMAIL_VERIFICATION=true" "AUTH_REQUIRE_EMAIL_VERIFICATION is not true" [ "$(container_env "$c" AUTH_REQUIRE_EMAIL_VERIFICATION)" = true ]
  check_verification_exempt "$c"
  hops=$(penv AUTH_TRUSTED_PROXY_HOPS || true)
  logs=$(docker logs "$c" 2>&1 || true)
  if [ -z "$hops" ]; then fail gateway-env "AUTH_TRUSTED_PROXY_HOPS is unset in .env.public"
  elif grep -qF "trusted proxy hops: $hops)" <<<"$logs"; then pass gateway-env "boot log: trusted proxy hops: $hops"
  else fail gateway-env "boot log has no 'trusted proxy hops: $hops'"; fi
  # The listen line prints the store before its async Redis connect finishes, so a healthy
  # gateway says "store: memory" there and "connected to Redis" a moment later (measured 2026-10-18).
  expect gateway-env "boot log: Redis store connected" "boot log shows no Redis connection" grep -qE "connected to Redis for shared rate-limit|rate-limit store: redis" <<<"$logs"
}

# Caveat: the geocode probe is rate-based. It expects the 1 r/s burst 5 bucket to be full, so
# 6 of 20 rapid requests pass (and reach the real upstream) and 14 get 503; a host so slow that
# the 20 requests span many seconds refills the bucket and under-counts 503s (a false FAIL, never
# a false PASS). One bucket serves every client: behind Funnel they share an address.
check_edge() {
  local base=${PUBLIC_EDGE_BASE:-https://127.0.0.1:4000} code limited urls=()
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$base/api/agent/claude/stream" || true)
  expect edge "POST /api/agent/claude/stream -> 404" "POST /api/agent/claude/stream -> ${code:-no answer}, expected 404" [ "$code" = 404 ]
  mapfile -t urls < <(yes "$base/api/geocode?q=x" | head -n 20)
  limited=$(curl -sk -o /dev/null -w '%{http_code}\n' --max-time 30 "${urls[@]}" | grep -c '^503$' || true)
  expect edge "20 rapid /api/geocode -> $limited x 503 (>= 14)" "20 rapid /api/geocode -> ${limited:-0} x 503, expected >= 14" [ "${limited:-0}" -ge 14 ]
}

# Through tailscaled's own proxy, each open port serves a certificate curl accepts. A tailscaled
# with no state dir (--state=mem: alone) cannot store the Funnel cert: every visitor gets a TLS
# internal-error alert while every other check passes (measured 2026-10-18).
# Caveat: curl exit 5 or 7 means the proxy itself is unreachable (a kernel-mode tailscaled has
# none), which is a SKIP; it proves the node's cert, not that every Funnel relay routes to it.
check_tls() {
  local host port rc
  host=$(origin_host)
  for port in $(funnel_ports | tr ',' ' '); do
    rc=0
    curl -sS --max-time 30 -x "$TS_PROXY" -o /dev/null "https://$host:$port/" 2>/dev/null || rc=$?
    case $rc in
    0) pass tls "https://$host:$port serves a valid certificate" ;;
    5 | 7) skip tls "cannot reach the proxy $TS_PROXY (curl $rc): the certificate is unchecked" ;;
    *) fail tls "https://$host:$port: no valid TLS through $TS_PROXY (curl $rc); tailscaled needs --statedir to keep a cert" ;;
    esac
  done
}

check_env_file() {
  local mode
  if [ ! -f "$ENV_FILE" ]; then fail env-file ".env.public is missing (make public-env)"; return; fi
  expect env-file ".env.public is git-ignored" ".env.public is not git-ignored" git -C "$GIT_REPO" check-ignore -q -- "$ENV_FILE"
  mode=$(stat -c %a "$ENV_FILE")
  expect env-file ".env.public mode is 600" ".env.public mode is $mode, expected 600" [ "$mode" = 600 ]
}

check_env_values() {
  local bad="" v
  [ -n "$(origin_host)" ] && [[ "$(penv PUBLIC_ORIGIN)" =~ ^https://[A-Za-z0-9.-]+$ ]] || bad+=" PUBLIC_ORIGIN"
  v=$(penv AUTH_LINK_SIGNING_KEY || true)
  [ "${#v}" -ge 32 ] || bad+=" AUTH_LINK_SIGNING_KEY(<32 chars)"
  [ -n "$(penv OSIONOS_ADMIN_EMAILS || true)" ] || bad+=" OSIONOS_ADMIN_EMAILS(empty: write emails or none)"
  is_int_between "$(penv AUTH_MAIL_DAILY_CAP || echo 50)" 1 50 || bad+=" AUTH_MAIL_DAILY_CAP(1-50)"
  is_int_between "$(penv AUTH_REGISTER_RATE_LIMIT_PER_HOUR || echo 10)" 1 10 || bad+=" AUTH_REGISTER_RATE_LIMIT_PER_HOUR(1-10)"
  v=$(penv AUTH_TRUSTED_PROXY_HOPS || true)
  is_int_between "${v:-x}" 0 9 || bad+=" AUTH_TRUSTED_PROXY_HOPS(measured integer)"
  expect env-values ".env.public values are in range" "invalid or unset:$bad" [ -z "$bad" ]
}

# $1: pre | full   $2: 443 | all | empty (the exposure the caller expects)
run_verify() {
  V_PASS=0 V_FAIL=0 V_SKIP=0
  check_env_file
  check_env_values
  check_node_name
  [ "$1" = pre ] || {
    check_exposure "${2:-}"
    check_tls
  }
  check_bundle_secrets
  check_bundle_links
  check_bridge_env
  check_ide_access
  check_gateway_env
  check_edge
  printf 'verify (%s): %d pass, %d fail, %d skip\n' "$1" "$V_PASS" "$V_FAIL" "$V_SKIP"
  [ "$V_FAIL" -eq 0 ]
}
