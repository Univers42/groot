#!/usr/bin/env bash
# public-verify-apps.sh — the checks for the Mail and Calendar static previews on the second
# Funnel node (the apps node): what it exposes, that no bridge or dev server stands behind it,
# the headers every response carries, and that nothing secret is in, or reaches, the two static
# images. Sourced by lib/public-verify.sh, which provides pass/fail/skip/expect, bundle_hits,
# bundle_links, container_env, svc_container, tls_probe and the PUBLIC_* settings; lib/
# public-tailnet.sh provides tsa, funnel_ports, funnel_targets and APPS_FUNNEL_MAP.
# No check prints a secret value: only variable names, pattern names and counts.
#
# With PUBLIC_MAIL_ORIGIN and PUBLIC_CALENDAR_ORIGIN both empty the apps are not deployed: the
# edge answers no Host, so the checks that need the edge or a container are a SKIP, never a pass.
# With either set, a missing node, container or image is a FAIL.
#
# Caveat: probes of what runs NOW. The bundle scans are greps (a secret split, encoded or built
# at run time is missed); the header and 404 probes go to the loopback listeners with the Host
# the Funnel would send, so they prove nginx's answer, not what a Funnel relay forwards.

APPS_MAIL_IMAGE="${PUBLIC_MAIL_IMAGE:-track-binocle/osionos-mail-web:public}"
APPS_CALENDAR_IMAGE="${PUBLIC_CALENDAR_IMAGE:-track-binocle/osionos-calendar-web:public}"
# MC2: files a Vite dev server or the bridges' token stores would serve; the prod image has none.
APPS_DEV_PATHS="/@vite/client /src/main.tsx /package.json /.mail-bridge-tokens.json /.calendar-bridge-tokens.json"
# MC13: variable names that must not exist in a static container.
APPS_FORBIDDEN_ENV='^(SMTP_|GOOGLE_|VAULT_|KONG_)|^(SERVICE_ROLE_KEY|JWT_SECRET)$'
# MC5: name|mode|pattern (F fixed string, E extended regex).
APPS_BUNDLE_PATTERNS=$'GOCSPX-|F|GOCSPX-\nclient_secret|F|client_secret\nservice_role|F|service_role\nlocalhost:|F|localhost:\nJWT-shaped|E|eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}'

# "https://host[:port]" of the app's origin, or empty. $1: mail | calendar
app_origin() {
  local name=${1^^}
  penv "PUBLIC_${name}_ORIGIN" || true
}
apps_configured() { [ -n "$(app_origin mail)$(app_origin calendar)" ]; }
# Loopback listener of an app: the local port paired with its public port in APPS_FUNNEL_MAP.
app_port() {
  local want=443 pair
  [ "$1" = calendar ] && want=8443
  for pair in $APPS_FUNNEL_MAP; do [ "${pair%%:*}" = "$want" ] && printf '%s' "${pair##*:}"; done
}
# The Host header the Funnel sends for the app: its origin without the scheme.
app_host_header() {
  local o
  o=$(app_origin "$1")
  printf '%s' "${o#https://}"
}
# DNS name of the apps node: from the origins, else from the running node.
apps_host() {
  local o h
  o=$(app_origin mail)
  [ -n "$o" ] || o=$(app_origin calendar)
  h=${o#https://}
  if [ -z "$h" ]; then h=$(tsa status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true); fi
  h=${h%.}
  printf '%s' "${h%%[:/]*}"
}
container_env_names() { docker exec "$1" env 2>/dev/null | cut -d= -f1 || true; }

# SKIP when the apps are not deployed, FAIL when they are and $2 is missing; returns 1 either way.
apps_absent() {
  if apps_configured; then fail "$1" "$2"; else skip "$1" "apps not deployed (no PUBLIC_MAIL_ORIGIN / PUBLIC_CALENDAR_ORIGIN): $2"; fi
  return 1
}

# $1: the verify scope (apps = the Funnel must be open on the apps node).
check_exposure2() {
  local have targets want_targets dns host
  if ! dns=$(tsa status --json 2>/dev/null | jq -r '.Self.DNSName // empty'); then
    apps_absent exposure2 "the apps node is not running (scripts/public-node.sh start)" || true
    return
  fi
  have=$(funnel_ports tsa || true)
  if [ -z "$have" ]; then
    if [ "$1" = apps ] || apps_configured; then
      fail exposure2 "apps node $dns has its Funnel closed"
    else skip exposure2 "apps node $dns runs with its Funnel closed and no origin is set"; fi
    return
  fi
  targets=$(funnel_targets tsa | paste -sd, -)
  want_targets="443 / 127.0.0.1:$(app_port mail),8443 / 127.0.0.1:$(app_port calendar)"
  host=$(apps_host)
  if [ "$have" != 443,8443 ] || [ "$targets" != "$want_targets" ]; then
    fail exposure2 "apps node funnel ports '$have' -> '$targets', expected exactly 443,8443 -> $want_targets"
  elif [ -n "$(app_origin mail)" ] && [ "$dns" != "$host." ]; then
    fail exposure2 "apps node DNS name is '$dns', the origins want '$host.'"
  else pass exposure2 "apps node ${dns}: funnel $have -> $targets"; fi
}

# MC1: no bridge container, and neither node proxies to a bridge port.
check_nobridge() {
  local running mapped
  running=$(docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null || echo unreadable)
  if [ "$running" = unreadable ]; then
    fail nobridge "cannot list the containers of project $PROJECT"
    return
  fi
  running=$(grep -E '^(mail|calendar)-bridge$' <<<"$running" | paste -sd, - || true)
  mapped=$({
    funnel_targets ts || true
    funnel_targets tsa || true
  } | grep -E ':(4100|4200)$' | paste -sd, - || true)
  if [ -n "$running" ]; then
    fail nobridge "bridge container(s) running in $PROJECT: $running"
  elif [ -n "$mapped" ]; then
    fail nobridge "a Funnel node proxies to a bridge port: $mapped"
  else pass nobridge "no mail-bridge or calendar-bridge container; no node maps 4100 or 4200"; fi
}

# One curl of an app's loopback listener with the Funnel's Host: headers (-D) or the code.
app_get() { # app path [curl args...]
  local app=$1 path=$2
  shift 2
  curl -sk --max-time 10 -H "Host: $(app_host_header "$app")" "$@" "https://127.0.0.1:$(app_port "$app")$path"
}

# MC2: a Vite dev server upstream would serve these; the prod image and the edge answer 404.
check_nodev() {
  local app path code bad="" n=0
  apps_configured || {
    apps_absent nodev "the edge answers no Host" || true
    return
  }
  for app in mail calendar; do
    for path in $APPS_DEV_PATHS; do
      code=$(app_get "$app" "$path" -o /dev/null -w '%{http_code}' || true)
      n=$((n + 1))
      [ "$code" = 404 ] || bad+=" $app$path=${code:-none}"
    done
  done
  expect nodev "$n probes (dev client, entry, package.json, token files) -> 404" "not 404:$bad" [ -z "$bad" ]
}

# What is wrong with one response's headers ($1); empty when nothing is. MC4.
apphdrs_problems() {
  local headers=$1 csp bad="" d
  [ -n "$headers" ] || {
    printf 'no answer'
    return
  }
  csp=$(grep -i '^content-security-policy:' <<<"$headers" | head -n1 | cut -d: -f2- | tr ';' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  for d in "frame-ancestors $(penv PUBLIC_ORIGIN || true):8443" "default-src 'self'" "script-src 'self'" "connect-src 'self'"; do
    grep -qFx -- "$d" <<<"$csp" || bad+=" csp:'$d'"
  done
  grep -qi '^x-content-type-options: *nosniff *$' <<<"$headers" || bad+=" nosniff"
  grep -qi '^referrer-policy: *no-referrer *$' <<<"$headers" || bad+=" referrer-policy"
  grep -qi '^strict-transport-security:' <<<"$headers" || bad+=" hsts"
  if grep -qi '^access-control-allow-origin:' <<<"$headers"; then bad+=" ACAO-present"; fi
  if grep -qi '^x-frame-options:' <<<"$headers"; then bad+=" X-Frame-Options-present"; fi
  printf '%s' "$bad"
}

# MC4 on the page and on an nginx 404, for both apps.
check_apphdrs() {
  local app path headers problems bad=""
  apps_configured || {
    apps_absent apphdrs "the edge answers no Host" || true
    return
  }
  for app in mail calendar; do
    for path in / /no-such-file-apphdrs; do
      headers=$(app_get "$app" "$path" -D - -o /dev/null | tr -d '\r' || true)
      problems=$(apphdrs_problems "$headers")
      [ -z "$problems" ] || bad+=" $app$path:$problems;"
    done
  done
  expect apphdrs "mail and calendar, on / and on a 404: CSP (frame-ancestors, default, script, connect), nosniff, no-referrer, HSTS, no CORS, no X-Frame-Options" "headers wrong:$bad" [ -z "$bad" ]
}

# MC5: the patterns above plus every secret value of the env files, in both static images.
# Prints "NAME(count)" for each offender, "unscannable:IMAGE" when an image cannot be read.
bundle2_offenders() {
  local image name mode pattern hits key file value
  for image in "$APPS_MAIL_IMAGE" "$APPS_CALENDAR_IMAGE"; do
    hits=$(docker run --rm --entrypoint sh "$image" -c 'find /usr/share/nginx/html -type f | wc -l' 2>/dev/null | tr -d '[:space:]' || true)
    if ! [[ "$hits" =~ ^[0-9]+$ ]] || [ "$hits" -eq 0 ]; then
      printf 'unscannable:%s ' "$image"
      continue
    fi
    while IFS='|' read -r name mode pattern; do
      hits=$(V="$pattern" bundle_hits "$image" "$mode" || true)
      [ "$hits" = 0 ] || printf '%s:%s(%s) ' "${image##*/}" "$name" "${hits:-?}"
    done <<<"$APPS_BUNDLE_PATTERNS"
    for key in $BUNDLE_SECRET_KEYS; do
      for file in "$LOCAL_ENV" "$REMOTE_ENV" "$ENV_FILE"; do
        value=$(get_env "$file" "$key" || true)
        [ -n "$value" ] || continue
        hits=$(V="$value" bundle_hits "$image" || true)
        [ "$hits" = 0 ] || printf '%s:%s(%s) ' "${image##*/}" "$key" "${hits:-?}"
      done
    done
  done
}
check_bundle2() {
  local bad
  apps_configured || docker image inspect "$APPS_MAIL_IMAGE" "$APPS_CALENDAR_IMAGE" >/dev/null 2>&1 ||
    {
      apps_absent bundle2 "the static images are not built" || true
      return
    }
  bad=$(bundle2_offenders)
  expect bundle2 "0 files in $APPS_MAIL_IMAGE and $APPS_CALENDAR_IMAGE hold a client secret, JWT, service_role, localhost: or an env-file secret" "found: ${bad% }" [ -z "$bad" ]
}

# Files in the osionos app image holding ORIGIN as a complete string literal ("…", '…' or `…`),
# so Mail's origin does not match Calendar's, which begins with it.
origin_hits() {
  V1="$2\"" V2="$2'" V3="$2\`" docker run --rm -e V1 -e V2 -e V3 --entrypoint sh "$1" -c \
    'grep -rlF -e "$V1" -e "$V2" -e "$V3" /usr/share/nginx/html /app /srv 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]'
}

# Problems with the pair of origins themselves; empty when they are consistent.
appurls_config_problems() {
  local mail cal host main
  mail=$(app_origin mail)
  cal=$(app_origin calendar)
  host=$(apps_host)
  main=$(origin_host)
  if [ -z "$mail" ] || [ -z "$cal" ]; then
    printf 'only one of PUBLIC_MAIL_ORIGIN, PUBLIC_CALENDAR_ORIGIN is set'
    return
  fi
  [[ "$mail" =~ ^https://[A-Za-z0-9.-]+$ ]] || {
    printf 'PUBLIC_MAIL_ORIGIN is not https://host'
    return
  }
  [ "$cal" = "$mail:8443" ] || {
    printf 'PUBLIC_CALENDAR_ORIGIN is not PUBLIC_MAIL_ORIGIN:8443'
    return
  }
  [ "$host" != "$main" ] || printf 'the apps origins share PUBLIC_ORIGIN host %s (MC3: a separate hostname)' "$main"
}

# MC8: the osionos app image links to the configured origins and to no localhost.
check_appurls() {
  local problems app origin hits bad="" links
  apps_configured || {
    skip appurls "origins unset: the Mail and Calendar tabs are hidden (bundle-links covers localhost)"
    return
  }
  problems=$(appurls_config_problems)
  if [ -n "$problems" ]; then
    fail appurls "$problems"
    return
  fi
  for app in mail calendar; do
    origin=$(app_origin "$app")
    hits=$(origin_hits "$APP_IMAGE" "$origin" || true)
    [[ "$hits" =~ ^[0-9]+$ ]] && [ "$hits" -gt 0 ] || bad+=" $origin(${hits:-unscannable})"
  done
  links=$(bundle_links "$APP_IMAGE" | head -n1 | tr -d '[:space:]' || true)
  if [ -n "$bad" ]; then
    fail appurls "$APP_IMAGE does not contain the origin:$bad"
  elif [ "$links" != 0 ]; then
    fail appurls "$APP_IMAGE has ${links:-an unreadable count of} file(s) linking to localhost"
  else pass appurls "$APP_IMAGE contains $(app_origin mail) and $(app_origin calendar), no localhost"; fi
}

# MC13: names only, from `env` in each static container.
check_appenv() {
  local svc c names bad="" n=0
  for svc in mail-web calendar-web; do
    c=$(svc_container "$svc")
    [ -n "$c" ] || {
      apps_absent appenv "$svc is not running" || true
      return
    }
    names=$(container_env_names "$c")
    n=$((n + $(grep -c . <<<"$names" || true)))
    bad+=$(grep -E "$APPS_FORBIDDEN_ENV" <<<"$names" | sed "s/^/ $svc:/" | paste -sd' ' - || true)
  done
  expect appenv "mail-web and calendar-web hold $n variables, none of SMTP_ GOOGLE_ VAULT_ KONG_ SERVICE_ROLE_KEY JWT_SECRET" "forbidden variable(s) present (values withheld):$bad" [ -z "$bad" ]
}

# $1: pre | full   $2: the verify scope
check_apps() {
  if [ "$1" != pre ]; then
    check_exposure2 "$2"
    tls_probe "$(apps_host)" "$(funnel_ports tsa || true)"
  fi
  check_nobridge
  check_nodev
  check_apphdrs
  check_bundle2
  check_appurls
  check_appenv
}
