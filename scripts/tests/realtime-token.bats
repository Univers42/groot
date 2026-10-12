#!/usr/bin/env bats
# grobase-link-target.sh's rt_token_ensure keeps the osionos realtime token valid after
# publish_env: the env the frontends build with must carry a VITE_BAAS_REALTIME_TOKEN the
# gateway accepts (HS256 over the grobase JWT_SECRET, iss grobase-realtime, sub
# osionos-live-demo), or the live views fall back to 15 s polling. These tests source
# scripts/lib/envfile.sh and scripts/lib/grobase-link-target.sh (after defining note and
# die, which grobase-link.sh normally provides) and cover the token only — no docker, no
# network: `stub` (below) stands in for the one container the function may run.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/realtime-token.bats

setup() {
  ENVF="$BATS_TEST_DIRNAME/../lib/envfile.sh"
  SCRIPT="$BATS_TEST_DIRNAME/../lib/grobase-link-target.sh"
  # What note/die print (to stderr) in the child; grobase-link.sh defines them for real.
  export NOTE_DIE='note() { printf "%s\n" "$*" >&2; }; die() { printf "%s\n" "$*" >&2; exit 1; }'
  # The docker stub's front: record argv (one arg per line), count the calls, record whether
  # RT_JWT_SECRET/RT_TOKEN were in its environment — never their values.
  # shellcheck disable=SC2016 # the stub body must reach the file literally, single quotes and all
  export STUB_REC='printf "%s\n" "$@" >"$STUB_DIR/argv"
printf x >>"$STUB_DIR/calls"
[ -n "${RT_JWT_SECRET+x}" ] && printf y >"$STUB_DIR/has_secret" || printf n >"$STUB_DIR/has_secret"
[ -n "${RT_TOKEN+x}" ] && printf y >"$STUB_DIR/has_token" || printf n >"$STUB_DIR/has_token"'
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
}

# stub CMD BODY — an executable CMD on PATH that runs BODY (sh); the stand-in for anything that
# would reach a daemon.
stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n%s\n' "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Runs shell code in a bash that defined note/die and sourced both libs, as grobase-link.sh does.
helper() { run bash -c "eval \"\$NOTE_DIE\"; . '$ENVF'; . '$SCRIPT' && $1"; }

@test "rt_token_ensure: no JWT_SECRET in SECRET_SRC — nothing runs, nothing changes" {
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'VITE_BAAS_REALTIME_TOKEN=stale.token.here\nKEEP=1\n' >"$env_local"
  chmod 600 "$env_local"
  cp "$env_local" "$BATS_TEST_TMPDIR/before"
  secret_src="$BATS_TEST_TMPDIR/secret.env"
  printf 'OTHER=1\n' >"$secret_src"
  stub docker "$STUB_REC
exit 0"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$env_local" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$STUB_DIR/argv" ]
  # an empty JWT_SECRET is the same case: get_env finds no value
  printf 'JWT_SECRET=\nOTHER=1\n' >"$secret_src"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$env_local" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$STUB_DIR/argv" ]
}

@test "rt_token_ensure: a token the node keeps — ENV_LOCAL untouched, the valid-until date" {
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'VITE_BAAS_REALTIME_TOKEN=cur.token.here\nKEEP=1\n' >"$env_local"
  chmod 600 "$env_local"
  cp "$env_local" "$BATS_TEST_TMPDIR/before"
  secret_src="$BATS_TEST_TMPDIR/secret.env"
  printf 'JWT_SECRET=sekret\n' >"$secret_src"
  stub docker "$STUB_REC
printf 'kept 1794326586\n'"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  cmp -s "$env_local" "$BATS_TEST_TMPDIR/before"
  [[ "$output" == *"realtime token valid until 2026-11-10"* ]]
}

@test "rt_token_ensure: a token the node mints — ENV_LOCAL rewritten, mode kept, nothing secret printed" {
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'VITE_BAAS_REALTIME_TOKEN=cur.token.here\nKEEP=1\n' >"$env_local"
  chmod 600 "$env_local"
  secret_src="$BATS_TEST_TMPDIR/secret.env"
  printf 'JWT_SECRET=sekret\n' >"$secret_src"
  stub docker "$STUB_REC
printf 'minted 1794326586\nhhh.bbb.sss\n'"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [ "$(cat "$env_local")" = "VITE_BAAS_REALTIME_TOKEN=hhh.bbb.sss
KEEP=1" ]
  [ "$(stat -c %a "$env_local")" = 600 ]
  [[ "$output" == *"minted, valid until 2026-11-10"* ]]
  [[ "$output" != *hhh.bbb.sss* ]]
  [[ "$output" != *sekret* ]]
}

@test "rt_token_ensure: one container; argv carries flags and -e names, the values only its environment" {
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'VITE_BAAS_REALTIME_TOKEN=cur.token.here\nKEEP=1\n' >"$env_local"
  chmod 600 "$env_local"
  secret_src="$BATS_TEST_TMPDIR/secret.env"
  printf 'JWT_SECRET=sekret\n' >"$secret_src"
  stub docker "$STUB_REC
printf 'kept 1794326586\n'"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [ "$(wc -c <"$STUB_DIR/calls")" -eq 1 ]
  grep -qx -- '--network' "$STUB_DIR/argv"
  grep -qx -- 'none' "$STUB_DIR/argv"
  grep -qx -- 'RT_JWT_SECRET' "$STUB_DIR/argv"
  grep -qx -- 'RT_TOKEN' "$STUB_DIR/argv"
  [ "$(grep -c 'sekret' "$STUB_DIR/argv")" -eq 0 ]
  [ "$(grep -c 'cur.token.here' "$STUB_DIR/argv")" -eq 0 ]
  [ "$(cat "$STUB_DIR/has_secret")" = y ]
  [ "$(cat "$STUB_DIR/has_token")" = y ]
}

@test "rt_token_ensure: docker failing or garbage output — one polling warning, ENV_LOCAL untouched, status 0" {
  env_local="$BATS_TEST_TMPDIR/env.local"
  printf 'VITE_BAAS_REALTIME_TOKEN=cur.token.here\nKEEP=1\n' >"$env_local"
  chmod 600 "$env_local"
  cp "$env_local" "$BATS_TEST_TMPDIR/before"
  secret_src="$BATS_TEST_TMPDIR/secret.env"
  printf 'JWT_SECRET=sekret\n' >"$secret_src"
  stub docker "$STUB_REC
exit 1"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [[ "$output" == *polling* ]]
  cmp -s "$env_local" "$BATS_TEST_TMPDIR/before"
  # output in neither shape is the same outcome
  stub docker "$STUB_REC
printf 'kept notanumber\n'"
  helper "rt_token_ensure '$env_local' '$secret_src'"
  [ "$status" -eq 0 ]
  [[ "$output" == *polling* ]]
  cmp -s "$env_local" "$BATS_TEST_TMPDIR/before"
}
