#!/usr/bin/env bats
# `make healthcheck` probes grobase's Kong at BAAS_URL (infrastructure/makes/common.mk). A local
# Kong wins; a linked machine (make link) has none and must probe the link's loopback port, not
# 8000. Drives the real Makefile against a fake `docker` and a fake link state.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils && bats scripts/tests/healthcheck-baas-url.bats'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/link"
  cat >"$BIN/docker" <<'FAKE'
#!/bin/sh
# Fake docker: `port` answers KONG_PORT when a local Kong is up; everything else is a no-op.
[ "$1" = port ] && [ -n "${KONG_PORT:-}" ] && echo "0.0.0.0:$KONG_PORT"
exit 0
FAKE
  chmod +x "$BIN/docker"
  PATH="$BIN:$PATH"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF=/dev/null # this machine's .env.grobase-link must not leak in
  unset KONG_PORT GROBASE_LINK_HOST_PORT
}

link_mode() { printf 'mode=%s\ntarget=x\n' "$1" >"$GROBASE_LINK_DIR/state"; }
baas_url() { make -s -C "$REPO" --eval 'print-baas-url: ; @echo $(BAAS_URL)' print-baas-url; }

@test "ssh link and no local Kong: the link's loopback port" {
  link_mode ssh
  GROBASE_LINK_HOST_PORT=28000 run baas_url
  [ "$output" = "http://127.0.0.1:28000" ]
}

@test "direct link: the link's loopback port" {
  link_mode direct
  GROBASE_LINK_HOST_PORT=28123 run baas_url
  [ "$output" = "http://127.0.0.1:28123" ]
}

@test "a local Kong wins over the link" {
  link_mode ssh
  KONG_PORT=8001 GROBASE_LINK_HOST_PORT=28000 run baas_url
  [ "$output" = "http://127.0.0.1:8001" ]
}

@test "local mode, no Kong up yet: 8000" {
  link_mode local
  GROBASE_LINK_HOST_PORT=28000 run baas_url
  [ "$output" = "http://127.0.0.1:8000" ]
}

@test "no link at all: 8000" {
  GROBASE_LINK_HOST_PORT=28000 run baas_url
  [ "$output" = "http://127.0.0.1:8000" ]
}

@test "ssh link with the loopback port disabled (0): 8000" {
  link_mode ssh
  GROBASE_LINK_HOST_PORT=0 run baas_url
  [ "$output" = "http://127.0.0.1:8000" ]
}
