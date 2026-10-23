#!/usr/bin/env bats
# grobase-link.sh's parsers decide how the frontends reach grobase: a mis-read target
# would open the link to the wrong host, or probe nothing. These tests source the script
# (its dispatcher steps aside when sourced) and cover the pure helpers, the settings
# precedence, the state file and the exit codes only — no ssh, no docker, no network: `stub`
# (below) stands in for any command that would reach one.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  # Point the settings file away from the repo's real ./.env.grobase-link: a test must not
  # inherit this machine's target.
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
}

# stub CMD BODY — an executable CMD on PATH that runs BODY (sh); the stand-in for anything that
# would reach a network, a daemon or a resolver.
stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n%s\n' "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
# Runs shell code in a bash that sourced the script, so its functions are callable.
helper() { run bash -c "source '$SCRIPT' && $1"; }
resolve_target() { run env GROBASE_TARGET="$1" bash -c "source '$SCRIPT' && resolve"; }

@test "ssh_args: ssh:// with user and port becomes dest plus -p" {
  helper 'ssh_args ssh://alice@10.0.0.7:2222'
  [ "$status" -eq 0 ]
  [ "$output" = "alice@10.0.0.7 -p 2222" ]
}

@test "ssh_args: an alias and a user@host pass through untouched" {
  helper 'ssh_args b2b; ssh_args ssh://alice@box'
  [ "$output" = $'b2b\nalice@box' ]
}

@test "url_hostport: the scheme sets the default port; explicit port and path are split off" {
  helper 'url_hostport http://kong.lan/; url_hostport https://api.example.org; url_hostport https://10.1.2.3:8443/x/y'
  [ "$output" = $'kong.lan 80\napi.example.org 443\n10.1.2.3 8443' ]
}

@test "api_url: explicit wins, http(s) targets pass through, local maps to the WAF, others fail" {
  helper 'api_url ssh://b2b https://vm.example.ts.net:8443/'
  [ "$status" -eq 0 ]
  [ "$output" = "https://vm.example.ts.net:8443" ]
  helper 'api_url https://kong.example.org/ ""'
  [ "$status" -eq 0 ]
  [ "$output" = "https://kong.example.org" ]
  helper 'api_url local ""'
  [ "$output" = "https://127.0.0.1:8443" ]
  helper 'api_url ssh://b2b ""'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  helper 'api_url auto ""'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "resolve: an explicit target is taken as given, nothing is probed" {
  resolve_target local
  [ "$output" = "local local" ]
  resolve_target ssh://alice@box:2222
  [ "$output" = "ssh ssh://alice@box:2222" ]
  resolve_target https://kong.example.org
  [ "$output" = "direct https://kong.example.org" ]
}

@test "conf: the environment beats the file, the file beats the default; an unknown key exits 1" {
  printf '# this machine\nGROBASE_TARGET=ssh://box\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = ssh://box ]
  run env GROBASE_TARGET=local bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = local ]
  run env GROBASE_TARGET= bash "$SCRIPT" conf GROBASE_TARGET # make's unset variable arrives empty
  [ "$output" = ssh://box ]
  run bash "$SCRIPT" conf GROBASE_LINK_HOST_PORT
  [ "$output" = 28000 ]
  run bash "$SCRIPT" conf NOPE
  [ "$status" -eq 1 ]
}

@test "conf: without a file every setting is its default; no key lists all five" {
  run bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = auto ]
  run bash "$SCRIPT" conf
  [ "$status" -eq 0 ]
  [ "$output" = $'GROBASE_TARGET=auto\nGROBASE_LINK_HOST_PORT=28000\nGROBASE_REMOTE_DIR=/opt/grobase\nGROBASE_API_URL=\nGROBASE_CA_FILE=' ]
}

@test "conf: GROBASE_CA_FILE — the environment beats the file, the file beats empty" {
  printf 'GROBASE_CA_FILE=/from/file.pem\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" conf GROBASE_CA_FILE
  [ "$output" = /from/file.pem ]
  run env GROBASE_CA_FILE=/from/env.pem bash "$SCRIPT" conf GROBASE_CA_FILE
  [ "$output" = /from/env.pem ]
}

@test "resolve: the file's target is resolved like one from the environment" {
  printf 'GROBASE_TARGET=https://kong.example.org\n' >"$GROBASE_LINK_CONF"
  helper 'resolve'
  [ "$output" = "direct https://kong.example.org" ]
}

@test "state: set then get round-trips a target that contains ':' and '@'" {
  helper 'mkdir -p "$LINK_DIR"; state_set ssh ssh://alice@box:2222; state_get target; state_get mode'
  [ "$output" = $'ssh://alice@box:2222\nssh' ]
}

@test "mode and status: exit 1 with no link; mode prints the recorded mode once set" {
  run bash "$SCRIPT" mode
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"make link"* ]]
  mkdir -p "$GROBASE_LINK_DIR" && printf 'mode=direct\ntarget=https://k\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" mode
  [ "$status" -eq 0 ]
  [ "$output" = direct ]
}

@test "--help exits 0 and names every verb; misuse exits 1" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  for verb in up down status env verify mode conf api-url docker-host; do [[ "$output" == *" $verb "* ]]; done
  run bash "$SCRIPT" bogus
  [ "$status" -eq 1 ]
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "up: an explicit local target still needs mini-baas-kong on this daemon" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/docker" # a daemon running nothing
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  run env GROBASE_TARGET=local PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"no mini-baas-kong on this daemon"* ]]
  [ ! -e "$GROBASE_LINK_DIR/state" ]
}

@test "docker-host: this daemon in local mode, the ssh target as a DOCKER_HOST in ssh mode, refused in direct mode" {
  mkdir -p "$GROBASE_LINK_DIR"
  printf 'mode=local\ntarget=local\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'mode=ssh\ntarget=b2b\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$output" = ssh://b2b ]
  printf 'mode=ssh\ntarget=ssh://alice@box:2222\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$output" = ssh://alice@box:2222 ]
  printf 'mode=direct\ntarget=https://k\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$status" -eq 1 ]
  [[ "$output" == *"no postgres"* ]]
}

@test "api-url: the setting beats derivation; an ssh target without it exits 1 naming GROBASE_API_URL" {
  run env GROBASE_TARGET=ssh://b2b bash "$SCRIPT" api-url
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_API_URL"* ]]
  run env GROBASE_TARGET=ssh://b2b GROBASE_API_URL=https://vm.example.ts.net:8443/ bash "$SCRIPT" api-url
  [ "$status" -eq 0 ]
  [ "$output" = "https://vm.example.ts.net:8443" ]
}

@test "own_link_dir: an empty LINK_DIR another user made (dockerd after a reboot) is replaced by ours" {
  [ "$(id -u)" -eq 0 ] || skip "needs root to make a dir owned by someone else (the bats container runs as root)"
  mkdir -p "$GROBASE_LINK_DIR" && chown 65534 "$GROBASE_LINK_DIR"
  helper 'own_link_dir && stat -c "%u %a" "$LINK_DIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "0 700" ]
}

@test "own_link_dir: a foreign LINK_DIR that is not empty is refused, named, and left alone" {
  [ "$(id -u)" -eq 0 ] || skip "needs root to make a dir owned by someone else (the bats container runs as root)"
  mkdir -p "$GROBASE_LINK_DIR" && touch "$GROBASE_LINK_DIR/keep" && chown -R 65534 "$GROBASE_LINK_DIR"
  helper 'own_link_dir'
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not empty"* ]]
  [ -e "$GROBASE_LINK_DIR/keep" ]
}

# Red on mawk 1.3.4 20260129 before the fix (127.0.0.1127.0.0.1:8000); busybox awk, which
# the bats image ships, never showed it, so this guards the hosts whose awk is mawk.
@test "remote_endpoints: a loopback publish is kept, a wildcard publish becomes loopback, no publish takes the container IP" {
  helper 'mux() { cat >/dev/null; printf "%s\n" "N /mini-baas-kong 172.18.0.28" "P /mini-baas-kong 8000/tcp 127.0.0.1:8000" \
    "N /mini-baas-waf 172.18.0.30" "P /mini-baas-waf 443/tcp 0.0.0.0:8443" "P /mini-baas-waf 80/tcp :::8880" \
    "N /mini-baas-realtime 172.18.0.26" "P /mini-baas-realtime 4000/tcp -"; }; remote_endpoints'
  [ "$status" -eq 0 ]
  [ "$output" = $'kong 8000 127.0.0.1:8000\nwaf 443 127.0.0.1:8443\nwaf 80 127.0.0.1:8880\nrealtime 4000 172.18.0.26:4000' ]
}

@test "resolve_ipv4: the first IPv4 getent gives; the name itself when getent knows none" {
  stub getent 'printf "192.168.1.132   STREAM grobase.track-binocle.test\n10.9.9.9 STREAM x\n"'
  helper 'resolve_ipv4 grobase.track-binocle.test'
  [ "$output" = 192.168.1.132 ]
  stub getent 'exit 2'
  helper 'resolve_ipv4 kong.lan; resolve_ipv4 10.1.2.3'
  [ "$output" = $'kong.lan\n10.1.2.3' ]
}

@test "kong_addr: TLS to the resolved IP, verified against the URL's name and the given CA" {
  stub getent 'echo "192.168.1.132 STREAM h"'
  helper 'kong_addr https://grobase.track-binocle.test:8443 /link/ca.pem; kong_addr http://kong.lan:8000 x'
  [ "$output" = $'OPENSSL:192.168.1.132:8443,verify=1,cafile=/link/ca.pem,commonname=grobase.track-binocle.test,snihost=grobase.track-binocle.test\nTCP:192.168.1.132:8000' ]
}

@test "direct_routes: Kong over the URL, Redis and Mailpit to the local stand-ins" {
  stub getent 'echo "100.94.119.97 STREAM h"'
  helper 'direct_routes https://100.94.119.97:8443 /link/ca.pem'
  [ "$output" = $'8000 OPENSSL:100.94.119.97:8443,verify=1,cafile=/link/ca.pem,commonname=100.94.119.97,snihost=100.94.119.97\n6379 TCP:grobase-link-redis:6379\n8025 TCP:grobase-link-mailpit:8025\n1025 TCP:grobase-link-mailpit:1025' ]
}

@test "up direct: GROBASE_CA_FILE is copied 644 into LINK_DIR and the relay verifies with it" {
  stub docker 'exit 0'
  stub ssh 'exit 0'
  stub getent 'echo "192.168.1.132 STREAM h"'
  printf 'CA\n' >"$BATS_TEST_TMPDIR/ca.pem"
  run env GROBASE_TARGET=https://grobase.track-binocle.test:8443 GROBASE_CA_FILE="$BATS_TEST_TMPDIR/ca.pem" bash "$SCRIPT" up
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$GROBASE_LINK_DIR/ca.pem")" = 644 ]
  [[ "$(sed -n 1p "$GROBASE_LINK_DIR/routes")" == *"cafile=/link/ca.pem,commonname=grobase.track-binocle.test"* ]]
  [ "$(wc -l <"$GROBASE_LINK_DIR/routes")" -eq 4 ]
  run env GROBASE_TARGET=https://grobase.track-binocle.test:8443 bash "$SCRIPT" up
  [ ! -e "$GROBASE_LINK_DIR/ca.pem" ]
  [[ "$(sed -n 1p "$GROBASE_LINK_DIR/routes")" == *"cafile=/etc/ssl/certs/ca-certificates.crt"* ]]
}

@test "up direct: an unreadable GROBASE_CA_FILE is refused, named, before any route is written" {
  stub docker 'exit 0'
  stub ssh 'exit 0'
  stub getent 'exit 2'
  run env GROBASE_TARGET=https://kong.example.org GROBASE_CA_FILE=/nonexistent/ca.pem bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_CA_FILE=/nonexistent/ca.pem"* ]]
  [ ! -e "$GROBASE_LINK_DIR/routes" ]
}

# probe_stub — docker as the target's Kong: answers the request it reads on stdin with
# PUBLISH_STATUS or MOUNTS_STATUS (nothing when unset), and keeps every request and argv.
probe_stub() {
  stub docker "req=\$(cat); printf '%s\n---\n' \"\$req\" >>'$BATS_TEST_TMPDIR/requests'; printf '%s\n' \"\$*\" >>'$BATS_TEST_TMPDIR/argv'
case \"\$req\" in
'POST /realtime/v1/publish '*) [ -z \"\$PUBLISH_STATUS\" ] || printf 'HTTP/1.1 %s X\r\n\r\n' \"\$PUBLISH_STATUS\" ;;
'GET /v1/tenants/me/mounts '*) [ -z \"\$MOUNTS_STATUS\" ] || printf 'HTTP/1.1 %s X\r\n\r\n' \"\$MOUNTS_STATUS\" ;;
esac"
  stub getent 'echo "100.94.119.97 STREAM h"'
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'SERVICE_ROLE_KEY=svc-1\nKEEP=1\n' >"$env_local"
}

@test "publish_env direct: a target refusing the publish route without credentials (403, Funnel) gets the socket and no service key; a 401 on the mount list names it" {
  probe_stub
  PUBLISH_STATUS=403 MOUNTS_STATUS=401 helper "publish_env direct '$env_local' https://baas.example.ts.net"
  [ "$status" -eq 0 ]
  grep -qx 'REALTIME_PUBLISH_URL=ws://mini-baas-kong:8000/realtime/v1/ws' "$env_local"
  grep -qx 'REALTIME_PUBLISH_APIKEY=' "$env_local"
  grep -qx 'OSIONOS_TENANT_MOUNTS_URL=http://mini-baas-kong:8000/v1/tenants/me/mounts' "$env_local"
  grep -qx 'OSIONOS_QUERY_ROUTER_URL=http://mini-baas-kong:8000/query/v1' "$env_local"
  grep -qx 'OSIONOS_ADAPTER_REGISTRY_URL=http://mini-baas-kong:8000/admin/v1' "$env_local"
  grep -qx 'KEEP=1' "$env_local"
  [ "$(grep -c 'svc-1' <<<"$output")" -eq 0 ]
  # Two probes, each over the relay's own verified TLS address, neither carrying a credential.
  [ "$(grep -c '^---$' "$BATS_TEST_TMPDIR/requests")" -eq 2 ]
  [ "$(grep -c 'OPENSSL:100.94.119.97:443,verify=1,cafile=/etc/ssl/certs/ca-certificates.crt,commonname=baas.example.ts.net,snihost=baas.example.ts.net,shut-none' "$BATS_TEST_TMPDIR/argv")" -eq 2 ]
  [ "$(grep -ciE '^(apikey|authorization|x-api-key):|svc-1' "$BATS_TEST_TMPDIR/requests")" -eq 0 ]
}

@test "publish_env direct: a 401 on the publish route keeps the service-key REST route; a 404 on the mount list leaves the registry" {
  probe_stub
  PUBLISH_STATUS=401 MOUNTS_STATUS=404 helper "publish_env direct '$env_local' http://192.168.1.132:8000"
  [ "$status" -eq 0 ]
  grep -qx 'REALTIME_PUBLISH_URL=http://mini-baas-kong:8000/realtime' "$env_local"
  grep -qx 'REALTIME_PUBLISH_APIKEY=svc-1' "$env_local"
  grep -qx 'OSIONOS_TENANT_MOUNTS_URL=' "$env_local"
  [ "$(grep -c 'svc-1' <<<"$output")" -eq 0 ]
  [ "$(grep -c 'TCP:100.94.119.97:8000' "$BATS_TEST_TMPDIR/argv")" -eq 2 ]
}

@test "publish_env direct: a target that answers nothing keeps the values written before the probes" {
  probe_stub
  helper "publish_env direct '$env_local' https://baas.example.ts.net"
  [ "$status" -eq 0 ]
  grep -qx 'REALTIME_PUBLISH_URL=http://mini-baas-kong:8000/realtime' "$env_local"
  grep -qx 'REALTIME_PUBLISH_APIKEY=svc-1' "$env_local"
  grep -qx 'OSIONOS_TENANT_MOUNTS_URL=' "$env_local"
}

@test "publish_env ssh and local: probe nothing, never add the mount list, and clear one a direct link left" {
  probe_stub
  helper "publish_env ssh '$env_local'"
  grep -qx 'REALTIME_PUBLISH_URL=' "$env_local"
  grep -qx 'REALTIME_PUBLISH_APIKEY=' "$env_local"
  grep -qx 'OSIONOS_QUERY_ROUTER_URL=http://mini-baas-kong:8000/query/v1' "$env_local"
  grep -qx 'OSIONOS_ADAPTER_REGISTRY_URL=http://mini-baas-kong:8000/admin/v1' "$env_local"
  grep -qx 'KEEP=1' "$env_local"
  helper "publish_env local '$env_local'"
  grep -qx 'OSIONOS_QUERY_ROUTER_URL=' "$env_local"
  grep -qx 'OSIONOS_ADAPTER_REGISTRY_URL=' "$env_local"
  [ "$(grep -c '^OSIONOS_TENANT_MOUNTS_URL=' "$env_local")" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/requests" ]
  printf 'OSIONOS_TENANT_MOUNTS_URL=http://mini-baas-kong:8000/v1/tenants/me/mounts\n' >>"$env_local"
  helper "publish_env ssh '$env_local'"
  grep -qx 'OSIONOS_TENANT_MOUNTS_URL=' "$env_local"
}

@test "publish_env direct writes OSIONOS_BAAS_KEEPALIVE=1" {
  probe_stub
  helper "publish_env direct '$env_local' https://baas.example.ts.net"
  [ "$status" -eq 0 ]
  grep -qx 'OSIONOS_BAAS_KEEPALIVE=1' "$env_local"
}

@test "publish_env ssh and local never add OSIONOS_BAAS_KEEPALIVE" {
  probe_stub
  helper "publish_env ssh '$env_local'"
  helper "publish_env local '$env_local'"
  [ "$(grep -c '^OSIONOS_BAAS_KEEPALIVE=' "$env_local")" -eq 0 ]
}

@test "publish_env ssh blanks an OSIONOS_BAAS_KEEPALIVE a direct link left" {
  probe_stub
  printf 'OSIONOS_BAAS_KEEPALIVE=1\n' >>"$env_local"
  helper "publish_env ssh '$env_local'"
  grep -qx 'OSIONOS_BAAS_KEEPALIVE=' "$env_local"
}
