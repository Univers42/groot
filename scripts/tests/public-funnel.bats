#!/usr/bin/env bats
# public-funnel.sh decides whether the internet reaches this host, so its refusals are the
# product: no Funnel without a passing `verify --pre`, never more than the scope asked for, never
# a secret in the output. tailscale, docker and curl are stubs on PATH that keep their state in
# files, so "which ports are open" and "which commands ran" are asserted on those files.
# Caveat: the stubs answer in the shape tailscale 1.104 / docker 2x / curl 8 gave when written;
# a real daemon answering differently is not covered (the script's own header says the same).
# `has`/`lacks` instead of `! cmd`: a negation that is not the last line never fails a bats test.
#
# Needs bash, git, jq, openssl, coreutils: apk add -q coreutils findutils git jq openssl bash
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 -c \
#   'apk add -q coreutils findutils git jq openssl && bats scripts/tests/public-funnel.bats'

bats_require_minimum_version 1.5.0

load public-funnel-helpers

@test "verify --pre passes on a fully public stack and has no FAIL or SKIP line" {
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "verify (pre): 37 pass, 0 fail, 0 skip"
  lacks "SKIP"
}

@test "up refuses without verify --pre: a mode-644 .env.public keeps the Funnel closed" {
  chmod 644 "$T/repo/.env.public"
  run_pf up
  [ "$status" -ne 0 ]
  has "FAIL  env-file"
  has "Funnel stays closed"
  [ "$(funnel_calls)" -eq 0 ]
}

@test "up 443 opens exactly 443 onto the website port, then verifies the exposure" {
  run_pf up 443
  [ "$status" -eq 0 ]
  [ "$(funnel_calls)" -eq 1 ]
  grep -qx 'funnel --bg --https=443 https+insecure://127.0.0.1:4322' "$T/ts.log"
  has "PASS  exposure       funnel ports: 443"
}

@test "up with no argument means 443" {
  run_pf up
  [ "$status" -eq 0 ]
  [ "$(funnel_calls)" -eq 1 ]
}

@test "up all is refused while AUTH_TRUSTED_PROXY_HOPS is empty" {
  set_env AUTH_TRUSTED_PROXY_HOPS ""
  run_pf up all
  [ "$status" -ne 0 ]
  has "AUTH_TRUSTED_PROXY_HOPS is unset"
  [ "$(funnel_calls)" -eq 0 ]
}

@test "up all opens 443, 8443 and 10000 onto 4322, 3001 and 4000" {
  run_pf up all
  [ "$status" -eq 0 ]
  [ "$(funnel_calls)" -eq 3 ]
  grep -qx 'funnel --bg --https=8443 https+insecure://127.0.0.1:3001' "$T/ts.log"
  grep -qx 'funnel --bg --https=10000 https+insecure://127.0.0.1:4000' "$T/ts.log"
  has "funnel ports: 443,8443,10000"
}

@test "up resets the Funnel when the post-open verify fails (a stray extra port)" {
  echo 8443 >"$T/funnel"
  run_pf up 443
  [ "$status" -ne 0 ]
  has "FAIL  exposure"
  grep -q 'funnel reset' "$T/ts.log"
  [ ! -s "$T/funnel" ]
}

@test "up rejects a scope other than 443, all or apps" {
  run_pf up 8443
  [ "$status" -ne 0 ]
  [ "$(funnel_calls)" -eq 0 ]
}

@test "down resets the Funnel of BOTH nodes and says the containers keep running" {
  printf '443\n8443\n' >"$T/funnel"
  run_pf down
  [ "$status" -eq 0 ]
  has "containers keep running on localhost"
  has "Funnel closed on: main, apps"
  [ ! -s "$T/funnel" ]
  [ ! -s "$T/funnel-apps" ]
  grep -qx '\[apps\] funnel reset' "$T/ts.log"
}

@test "down still resets the main node when the apps node is not running" {
  printf '443\n' >"$T/funnel"
  rm "$T/apps-node"
  run_pf down
  [ "$status" -eq 0 ]
  [ ! -s "$T/funnel" ]
  has "Funnel closed on: main"
  lacks "apps"
}

@test "down FAILs naming the socket when the apps node has state on disk but does not answer, after resetting main" {
  printf '443\n' >"$T/funnel"
  rm "$T/apps-node"
  mkdir -p "$T/state/tailscale-osionos-apps"
  run_pf down
  [ "$status" -eq 1 ]
  has "$T/state/tailscale-osionos-apps/tailscaled.sock"
  lacks "Funnel closed on: main, apps"
  [ ! -s "$T/funnel" ]
}

@test "up 443 whose post-open verify fails resets the apps node as well, not only the main one" {
  echo "10000 4000" >>"$T/funnel-apps"
  run_pf up 443
  [ "$status" -ne 0 ]
  has "FAIL  exposure2"
  [ ! -s "$T/funnel" ]
  [ ! -s "$T/funnel-apps" ]
}

@test "up apps whose post-open verify fails resets the main node as well, not only the apps one" {
  printf '443\n8443\n' >"$T/funnel"
  : >"$T/funnel-apps"
  run_pf up apps
  [ "$status" -ne 0 ]
  has "FAIL  exposure"
  [ ! -s "$T/funnel" ]
  [ ! -s "$T/funnel-apps" ]
}

@test "verify fails on an extra port beyond the expected set" {
  printf '443\n8443\n' >"$T/funnel"
  run_pf verify 443
  [ "$status" -eq 1 ]
  has "FAIL  exposure"
  has "expected exactly 443"
  run_pf verify
  [ "$status" -eq 1 ]
  has "expected 443 alone or 443,8443,10000"
}

@test "verify checks the served certificate of every open port through the tailnet proxy" {
  printf '443\n8443\n10000\n' >"$T/funnel"
  run_pf verify all
  [ "$status" -eq 0 ]
  has "PASS  tls            https://osionos.tail10f2ea.ts.net:443 serves a valid certificate"
  has "PASS  tls            https://osionos.tail10f2ea.ts.net:10000 serves a valid certificate"
  [ "$(grep -c 'socks5h://localhost:1055' "$T/tls.log")" -eq 5 ]
  has "PASS  tls2           https://osionos-apps.tail10f2ea.ts.net:8443 serves a valid certificate"
}

@test "verify FAILs a port whose TLS fails (no state dir) and up then resets the Funnel" {
  echo 443 >"$T/funnel"
  TLS_RC=35 run_pf verify 443
  [ "$status" -eq 1 ]
  has "FAIL  tls            https://osionos.tail10f2ea.ts.net:443: no valid TLS"
  has "needs --statedir"
  : >"$T/funnel"
  TLS_RC=35 run_pf up 443
  [ "$status" -ne 0 ]
  [ ! -s "$T/funnel" ]
}

@test "an unreachable tailnet proxy SKIPs the certificate check instead of passing it" {
  echo 443 >"$T/funnel"
  TLS_RC=7 PUBLIC_TS_PROXY=socks5h://localhost:1 run_pf verify 443
  [ "$status" -eq 0 ]
  has "SKIP  tls            cannot reach the proxy socks5h://localhost:1"
  lacks "PASS  tls"
}

@test "verify --pre never probes the certificate: nothing is open yet" {
  run_pf verify --pre
  [ ! -e "$T/tls.log" ]
}

@test "verify with no scope SKIPs a closed Funnel instead of passing it; with a scope it FAILs" {
  run_pf verify
  has "SKIP  exposure"
  lacks "PASS  exposure  "
  run_pf verify 443
  [ "$status" -eq 1 ]
  has "FAIL  exposure"
}

@test "verify fails on a wrong DNS name" {
  TS_DNS=laptop.tail10f2ea.ts.net. run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  node-name"
}

@test "verify fails when a secret is found in a bundle, naming the key and never the value" {
  RUN_HITS=1 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  bundle-secret  JWT_SECRET (from .env.local) found in 1 file(s) of track-binocle/osionos-web:public"
  for s in $SECRETS; do lacks "$s"; done
}

@test "verify fails when a public image cannot be scanned at all" {
  stub docker 'case "$1" in run) exit 125 ;; ps) echo cid ;; esac'
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "could not be scanned in track-binocle/osionos-web:public"
}

@test "verify fails on a non-empty OSIONOS_AGENT_CLAUDE and withholds its value" {
  echo "OSIONOS_AGENT_CLAUDE=hunter2-agent" >>"$T/env-bridge"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  bridge-env     OSIONOS_AGENT_CLAUDE is set (value withheld)"
  lacks "hunter2-agent"
}

@test "verify fails when the bridge admin list differs from .env.public" {
  set_env OSIONOS_ADMIN_EMAILS other@example.test
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "OSIONOS_ADMIN_EMAILS differs"
}

@test "verify fails on a mode-644 .env.public" {
  chmod 644 "$T/repo/.env.public"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "mode is 644, expected 600"
}

@test "verify fails when .env.public is not git-ignored" {
  : >"$T/repo/.gitignore"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  env-file       .env.public is not git-ignored"
}

@test "verify fails on a mail cap above 50 and on an unset hop count" {
  set_env AUTH_MAIL_DAILY_CAP 51
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "AUTH_MAIL_DAILY_CAP(1-50)"
  set_env AUTH_MAIL_DAILY_CAP 50
  set_env AUTH_TRUSTED_PROXY_HOPS ""
  run_pf verify --pre
  has "AUTH_TRUSTED_PROXY_HOPS"
}

@test "verify fails on gateway drift: bypass on, wrong hops in the boot log, memory store" {
  printf 'TURNSTILE_BYPASS_LOCAL=true\n' >>"$T/env-gw"
  echo 'listening (rate-limit store: memory, trusted proxy hops: 2)' >"$T/gw.log"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  gateway-env"
  has "no 'trusted proxy hops: 3'"
  has "no Redis connection"
}

@test "verify fails when the edge serves the claude stream or does not rate-limit geocode" {
  EDGE_STREAM=200 GEO_503=3 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "POST /api/agent/claude/stream -> 200, expected 404"
  has "3 x 503, expected >= 14"
}

@test "a SKIP is reported as SKIP and never counted as a pass" {
  : >"$T/repo/.env.local"
  echo "JWT_SECRET=jwt-AAAA-1111" >>"$T/repo/.env.local"
  run_pf verify --pre
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$out" | grep -c '^SKIP  bundle-secret')" -eq 5 ]
  [ "$(printf '%s\n' "$out" | grep -c '^PASS  bundle-secret')" -eq 2 ]
  has " 5 skip"
}

@test "no secret value reaches the output or a command line, passing or failing" {
  run_pf verify --pre
  for s in $SECRETS; do lacks "$s"; done
  RUN_HITS=2 run_pf verify --pre
  for s in $SECRETS; do lacks "$s"; done
  for s in $SECRETS; do
    if grep -qF -- "$s" "$T/docker.log" "$T/ts.log"; then
      echo "secret on a command line: $s" >&2
      return 1
    fi
  done
  grep -q 'run --rm -e V --entrypoint sh' "$T/docker.log"
}

@test "env creates .env.public at mode 600, mints a 32+ char key without printing it, keeps an existing one" {
  rm "$T/repo/.env.public"
  run_pf env
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$T/repo/.env.public")" = 600 ]
  key="$(sed -n 's/^AUTH_LINK_SIGNING_KEY=//p' "$T/repo/.env.public")"
  [ "${#key}" -ge 32 ]
  lacks "$key"
  has "decide OSIONOS_ADMIN_EMAILS"
  run_pf env
  [ "$(sed -n 's/^AUTH_LINK_SIGNING_KEY=//p' "$T/repo/.env.public")" = "$key" ]
}

@test "env refuses a short minted key: exit 1 and AUTH_LINK_SIGNING_KEY stays empty" {
  rm "$T/repo/.env.public"
  printf '#!/bin/sh\necho ab\n' >"$BIN/od"
  chmod +x "$BIN/od"
  run_pf env
  [ "$status" -eq 1 ]
  [ -z "$(sed -n 's/^AUTH_LINK_SIGNING_KEY=//p' "$T/repo/.env.public")" ]
  has "could not mint AUTH_LINK_SIGNING_KEY"
}

@test "status prints the node and ports, and an unknown command is a usage error" {
  echo 443 >"$T/funnel"
  run_pf status
  [ "$status" -eq 0 ]
  has "node:  osionos.tail10f2ea.ts.net."
  has "ports: 443"
  has "apps node:  osionos-apps.tail10f2ea.ts.net."
  has "apps ports: 443,8443"
  run_pf frobnicate
  [ "$status" -ne 0 ]
  has "usage:"
}

@test "verify prints the gateway's AUTH_VERIFICATION_EXEMPT as a value and passes when no admin is listed" {
  echo "AUTH_VERIFICATION_EXEMPT=dylan@gmail.com" >>"$T/env-gw"
  run_pf verify --pre
  [ "$status" -eq 0 ]
  has "PASS  gateway-env    AUTH_VERIFICATION_EXEMPT=dylan@gmail.com"
}

@test "verify prints <empty> for an unset exemption list" {
  run_pf verify --pre
  has "AUTH_VERIFICATION_EXEMPT=<empty>"
}

@test "verify FAILs when an exempt address is also an admin, ignoring case and spacing" {
  echo "AUTH_VERIFICATION_EXEMPT=other@example.test, Admin@Example.test" >>"$T/env-gw"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  gateway-env    AUTH_VERIFICATION_EXEMPT=other@example.test, Admin@Example.test lists an OSIONOS_ADMIN_EMAILS admin: admin@example.test"
}

@test "node_dns prints a node's DNS name, nothing when it has none, and fails when the daemon is silent" {
  ts() { "$TAILSCALE_BIN" --socket "$TAILSCALE_SOCKET" "$@"; }
  tsa() { "$TAILSCALE_BIN" --socket "$T/state/tailscale-osionos-apps/sock" "$@"; }
  . "$BATS_TEST_DIRNAME/../lib/public-tailnet.sh"
  [ "$(node_dns ts)" = "osionos.tail10f2ea.ts.net." ]
  [ "$(node_dns tsa)" = "osionos-apps.tail10f2ea.ts.net." ]
  rm "$T/apps-node"
  run node_dns tsa
  [ "$status" -eq 1 ]
}
