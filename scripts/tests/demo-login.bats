#!/usr/bin/env bats
# The demo account's password is minted per machine into ./.env.local. Its reader
# (scripts/lib/demo-login.sh) must refuse an unset or empty value instead of handing out an
# empty password, and demo-login-ensure.sh must apply it without the value ever reaching a
# process argv. docker is a stub that records its argv and answers as postgres would.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/demo-login.bats

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts/lib" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../lib/demo-login.sh" "$ROOT/scripts/lib/"
  cp "$BATS_TEST_DIRNAME/../demo-login-ensure.sh" "$ROOT/scripts/"
  export ENV_LOCAL="$ROOT/.env.local"
  printf 'OTHER=x\nDEMO_LOGIN_PASSWORD=pw-Sentinel-0123456789\n' >"$ENV_LOCAL"
  export ARGV_LOG="$BATS_TEST_TMPDIR/docker.argv" STDIN_LOG="$BATS_TEST_TMPDIR/docker.stdin"
  export PG_ANSWER=updated
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$ARGV_LOG"
case "$1" in
ps) printf 'mini-baas-postgres\n' ;;
exec) cat >>"$STDIN_LOG"; printf 'env:%s\n' "${DEMO_LOGIN_PASSWORD:-}" >>"$STDIN_LOG"; printf '%s\n' "$PG_ANSWER" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "demo_login_password prints the value from the file" {
  run sh -c '. "$1/scripts/lib/demo-login.sh"; demo_login_password "$2"' _ "$ROOT" "$ENV_LOCAL"
  [ "$status" -eq 0 ]
  [ "$output" = "pw-Sentinel-0123456789" ]
}

@test "demo_login_password: an empty value is an error naming the fix, not an empty password" {
  printf 'DEMO_LOGIN_PASSWORD=\n' >"$ENV_LOCAL"
  run sh -c '. "$1/scripts/lib/demo-login.sh"; demo_login_password "$2"' _ "$ROOT" "$ENV_LOCAL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEMO_LOGIN_PASSWORD is not set"*"gen-local-env.sh --sync"* ]]
}

@test "demo_login_password: an absent key or absent file is an error" {
  printf 'OTHER=x\n' >"$ENV_LOCAL"
  run sh -c '. "$1/scripts/lib/demo-login.sh"; demo_login_password "$2"' _ "$ROOT" "$ENV_LOCAL"
  [ "$status" -eq 1 ]
  run sh -c '. "$1/scripts/lib/demo-login.sh"; demo_login_password "$2"' _ "$ROOT" "$ROOT/nope"
  [ "$status" -eq 1 ]
}

@test "ensure: a missing password fails before docker is called" {
  printf 'OTHER=x\n' >"$ENV_LOCAL"
  run sh "$ROOT/scripts/demo-login-ensure.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEMO_LOGIN_PASSWORD is not set"* ]]
  [ ! -e "$ARGV_LOG" ]
}

@test "ensure: the password reaches psql by env NAME only — never argv, never SQL text" {
  run sh "$ROOT/scripts/demo-login-ensure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"password set from ./.env.local"* ]]
  [[ "$output" != *"pw-Sentinel"* ]]
  ! grep -q 'pw-Sentinel' "$ARGV_LOG"
  grep -q -- '-e DEMO_LOGIN_PASSWORD -e DEMO_LOGIN_EMAIL' "$ARGV_LOG"
  grep -q '^\\getenv pw DEMO_LOGIN_PASSWORD$' "$STDIN_LOG"
  [ "$(grep -c 'pw-Sentinel' "$STDIN_LOG")" -eq 1 ]
  grep -q '^env:pw-Sentinel-0123456789$' "$STDIN_LOG"
}

@test "ensure: an already-matching password is reported as current, exit 0" {
  PG_ANSWER=current run sh "$ROOT/scripts/demo-login-ensure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already matches"* ]]
}

@test "ensure: a missing account is a hard error" {
  PG_ANSWER=missing run sh "$ROOT/scripts/demo-login-ensure.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in auth.users"* ]]
}

@test "ensure: a stopped postgres is a hard error that names the fix" {
  PG_CONTAINER=other-pg run sh "$ROOT/scripts/demo-login-ensure.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-pg is not running"* ]]
}
