#!/usr/bin/env bats
# scripts/lib/grobase-link-verify.sh decides whether `make link` reports the frontends as
# reaching grobase. A wrong spec list probes the wrong names, a wrong consumer filter probes
# grobase's own containers or nothing, a lenient verdict calls a dead relay green. These
# tests source grobase-link.sh (which sources the lib) and cover the pure parts: the specs
# per mode, the consumer filter, the probe script's verdicts and the verb's exit codes, with
# a stub docker and a stub socat on PATH — no daemon, no network.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-verify.bats

load lib/nss-stubs

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GROBASE_LINK_DIR" "$BIN"
  export PATH="$BIN:$PATH"
  # probe_trust reads the real browser stores otherwise: an empty HOME and an absent CA keep it inert.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export LOCAL_CA_CERT="$BATS_TEST_TMPDIR/absent-ca.pem"
}

helper() { run bash -c "source '$SCRIPT' && $1"; }
link_state() { printf 'mode=%s\ntarget=%s\n' "$1" "$2" >"$GROBASE_LINK_DIR/state"; }

# A docker that lists a network of three (one frontend, one grobase container, the relay),
# runs no edge, and answers a probe run with STUB_PROBE's lines and STUB_PROBE_RC.
stub_docker() {
  cat >"$BIN/docker" <<'STUB'
#!/bin/sh
case "$1 $2" in
"network inspect") printf 'track-binocle-osionos-app-1\nmini-baas-kong\ntrack-binocle-grobase-link-1\n' ;;
"ps -q") ;;
"run --rm") printf '%b' "${STUB_PROBE:-}"; exit "${STUB_PROBE_RC:-0}" ;;
esac
STUB
  chmod +x "$BIN/docker"
}

# A socat that answers by the address it is given, like the services would.
stub_socat() {
  cat >"$BIN/socat" <<'STUB'
#!/bin/sh
cat >/dev/null
case "$*" in
*TCP:kong:8000*) printf 'HTTP/1.1 404 Not Found\r\nServer: kong\r\n' ;;
*TCP:redis:6379*) printf '+PONG\r\n' ;;
*TCP:mail:1025*) printf '220 mailpit ESMTP\r\n' ;;
*TCP:dead:*) ;;
esac
STUB
  chmod +x "$BIN/socat"
}

@test "verify_specs: local mode lists all five names; ssh and direct list the routed ones" {
  link_state local local
  helper 'verify_specs'
  [ "$output" = $'mini-baas-kong:8000:http\nmini-baas-redis:6379:redis\nmini-baas-mailpit:8025:http\nmailpit:1025:smtp\nmini-baas-realtime:4000:http' ]
  link_state ssh ssh://box
  printf '8000 UNIX-CONNECT:/link/kong-8000.sock\n1025 UNIX-CONNECT:/link/mailpit-1025.sock\n' >"$GROBASE_LINK_DIR/routes"
  helper 'verify_specs'
  [ "$output" = $'mini-baas-kong:8000:http\nmailpit:1025:smtp' ]
  link_state direct https://k
  printf '8000 OPENSSL:k:443,verify=1\n' >"$GROBASE_LINK_DIR/routes"
  helper 'verify_specs'
  [ "$output" = "mini-baas-kong:8000:http" ]
}

@test "link_consumers: grobase's own containers and the relay are not frontends" {
  stub_docker
  helper 'link_consumers'
  [ "$output" = "track-binocle-osionos-app-1" ]
}

@test "probe script: a real answer per kind is ok, silence is FAIL, and one FAIL fails the run" {
  stub_socat
  helper 'sh -c "$PROBE_SH" probe kong:8000:http redis:6379:redis mail:1025:smtp'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "ok   kong:8000  HTTP/1.1 404 Not Found" ]]
  [[ "${lines[1]}" == "ok   redis:6379  +PONG" ]]
  [[ "${lines[2]}" == "ok   mail:1025  220 mailpit ESMTP" ]]
  helper 'sh -c "$PROBE_SH" probe kong:8000:http dead:9:http'
  [ "$status" -eq 1 ]
  [[ "${lines[1]}" == "FAIL dead:9  no answer" ]]
}

@test "verify: exit 1 with no link, and with a link that routes nothing" {
  stub_docker
  rm -f "$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"make link"* ]]
  link_state ssh ssh://box
  run bash "$SCRIPT" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"no routes"* ]]
}

@test "verify: the frontend's probe decides; the edge is noted, not failed, while it is down" {
  stub_docker
  link_state ssh ssh://box
  printf '8000 UNIX-CONNECT:/link/kong-8000.sock\n' >"$GROBASE_LINK_DIR/routes"
  STUB_PROBE='ok   mini-baas-kong:8000  HTTP/1.1 404 Not Found\n' run bash "$SCRIPT" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"track-binocle-osionos-app-1"*"ok   mini-baas-kong:8000"* ]]
  [[ "$output" == *"local-https-proxy is not running"* ]]
  [[ "$output" == *"browser trust is checked once make certs has run"* ]]
  [[ "$output" == *"1 frontends reach grobase through the ssh link to ssh://box"* ]]
  STUB_PROBE='FAIL mini-baas-kong:8000  no answer\n' STUB_PROBE_RC=1 run bash "$SCRIPT" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 FAIL above"* ]]
}

@test "verify: a stale browser store turns a green verify into exit 1" {
  stub_docker
  stub_certutil "$BIN"
  stub_openssl "$BIN"
  link_state ssh ssh://box
  printf '8000 UNIX-CONNECT:/link/kong-8000.sock\n' >"$GROBASE_LINK_DIR/routes"
  printf 'CN=Fake CA,O=T\nv2\n' >"$LOCAL_CA_CERT"
  mkdir -p "$HOME/.pki/nssdb/certs"
  : >"$HOME/.pki/nssdb/cert9.db"
  printf 'CN=Fake CA,O=T\nv1\n' >"$HOME/.pki/nssdb/certs/Fake CA#1"
  STUB_PROBE='ok   mini-baas-kong:8000  HTTP/1.1 404 Not Found\n' run bash "$SCRIPT" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL chrome"*"stale"* ]]
  [[ "$output" == *"1 FAIL above"* ]]
}
