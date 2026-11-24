#!/usr/bin/env bats
# What an ssh link relays (ruling LM-4, LM-6, 2026-11-23). Kong was reached on its own :8000,
# around the VM's WAF, so bridge writes skipped CRS; the relay also carried realtime :4000, whose
# /v1/publish takes an unauthenticated POST (LM-1 U1: 400 "Topic is required" through :4000). Now
# 8000 is the WAF's plaintext port (VM 127.0.0.1:8880) and 4000 is not relayed. up_ssh runs with
# the master, the endpoint listing and ssh's forwards stubbed: nothing here reaches a host.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-ssh-routes.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
  export CAPABILITY_PAUSE=0
  mkdir -p "$GROBASE_LINK_DIR"
  MUX_LOG="$BATS_TEST_TMPDIR/mux.log"
  ENDPOINTS="$BATS_TEST_TMPDIR/endpoints"
  # remote_endpoints as the production VM answers it (addresses are documentation-shaped).
  printf '%s\n' 'kong 8000 127.0.0.1:8000' 'waf 443 127.0.0.1:8443' 'waf 80 127.0.0.1:8880' \
    'realtime 4000 172.18.0.26:4000' 'redis 6379 172.18.0.10:6379' 'mailpit 8025 172.18.0.11:8025' \
    'mailpit 1025 172.18.0.11:1025' 'tenant-control 3022 172.18.0.12:3022' >"$ENDPOINTS"
}

# up_ssh against $ENDPOINTS; every ssh -O call lands in $MUX_LOG.
ssh_up() {
  run bash -c "source '$SCRIPT'
open_master() { :; }
link_ide_plane() { :; }
remote_endpoints() { cat '$ENDPOINTS'; }
mux() { printf '%s\n' \"\$*\" >>'$MUX_LOG'; }
up_ssh b2b"
}

@test "8000 relays to the WAF's plaintext port (VM 127.0.0.1:8880), never to Kong's :8000; host tools get the same" {
  ssh_up
  [ "$status" -eq 0 ]
  grep -qx '8000 UNIX-CONNECT:/link/waf-80.sock' "$GROBASE_LINK_DIR/routes"
  grep -qx -- "-O forward -L $GROBASE_LINK_DIR/waf-80.sock:127.0.0.1:8880 x" "$MUX_LOG"
  grep -qx -- '-O forward -L 127.0.0.1:28000:127.0.0.1:8880 x' "$MUX_LOG"
  run ! grep -q ':127.0.0.1:8000 x$' "$MUX_LOG"
  [[ "$output" != *kong-8000* ]]
}

@test "4000 is not relayed, and nothing forwards to realtime, though realtime runs on the VM" {
  ssh_up
  [ "$status" -eq 0 ]
  run ! grep -q '^4000 ' "$GROBASE_LINK_DIR/routes"
  run ! grep -q 'realtime' "$MUX_LOG"
}

@test "mailpit and tenant-control keep their forwards" {
  ssh_up
  [ "$status" -eq 0 ]
  grep -qx '8025 UNIX-CONNECT:/link/mailpit-8025.sock' "$GROBASE_LINK_DIR/routes"
  grep -qx '1025 UNIX-CONNECT:/link/mailpit-1025.sock' "$GROBASE_LINK_DIR/routes"
  grep -qx -- "-O forward -L $GROBASE_LINK_DIR/tenant-control-3022.sock:172.18.0.12:3022 x" "$MUX_LOG"
  [ "$(wc -l <"$GROBASE_LINK_DIR/routes")" -eq 4 ]
}

@test "no WAF :80 on the VM: exit 1 naming the WAF, the routes untouched, no fallback to Kong's :8000" {
  printf '8000 UNIX-CONNECT:/link/waf-80.sock\n' >"$GROBASE_LINK_DIR/routes"
  cp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.before"
  grep -v '^waf 80 ' "$ENDPOINTS" >"$ENDPOINTS.new" && mv "$ENDPOINTS.new" "$ENDPOINTS"
  ssh_up
  [ "$status" -eq 1 ]
  [[ "$output" == *"WAF"* ]]
  cmp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.before"
  run ! grep -q ':127.0.0.1:8000 x$' "$MUX_LOG"
}

@test "status: Kong is asked through the socket the 8000 route names" {
  printf 'mode=ssh\ntarget=b2b\nconnect_ip=\n' >"$GROBASE_LINK_DIR/state"
  printf '8000 UNIX-CONNECT:/link/waf-80.sock\n6379 UNIX-CONNECT:/link/redis-6379.sock\n' >"$GROBASE_LINK_DIR/routes"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/ssh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/curl.log"\nprintf 404\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$SCRIPT" status
  [ "$status" -eq 0 ]
  grep -q -- "--unix-socket $GROBASE_LINK_DIR/waf-80.sock" "$BATS_TEST_TMPDIR/curl.log"
  [[ "$output" == *"waf-80.sock answers HTTP 404"* ]]
}
