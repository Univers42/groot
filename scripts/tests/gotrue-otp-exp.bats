#!/usr/bin/env bats
# scripts/lib/gotrue-otp-exp.sh fails when anything sets GoTrue's GOTRUE_MAILER_OTP_EXP below
# 86400 s, which would kill the token inside a 24 h confirm link (verdict B C14). The fixture
# is a synthetic grobase tree: compose files, its .env and the optional .env.gotrue; a stub
# docker stands in for a running mini-baas-gotrue. No real env file is read.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash coreutils findutils && bats scripts/tests/gotrue-otp-exp.bats'

bats_require_minimum_version 1.5.0

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib/gotrue-otp-exp.sh"
  G="$BATS_TEST_TMPDIR/grobase"
  mkdir -p "$G/orchestrators/compose/base" "$G/orchestrators/compose/overlays" "$BATS_TEST_TMPDIR/bin"
  cat >"$G/orchestrators/compose/base/auth-api.yml" <<'YML'
services:
  gotrue:
    env_file:
      - path: .env.gotrue
        required: false
    environment:
      GOTRUE_SMTP_HOST: ${SMTP_HOST:-mailpit}
      # GOTRUE_MAILER_OTP_EXP: 60   (a comment never counts)
YML
  printf 'SMTP_HOST=mailpit\n' >"$G/.env"
  export FAKE_GOTRUE="" FAKE_GOTRUE_ENV="$BATS_TEST_TMPDIR/gotrue.env"
  printf 'GOTRUE_SMTP_HOST=mailpit\n' >"$FAKE_GOTRUE_ENV"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
ps) [ -z "$FAKE_GOTRUE" ] || echo mini-baas-gotrue ;;
inspect) cat "$FAKE_GOTRUE_ENV" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

check() { run bash -c ". '$LIB' && gotrue_otp_exp_check '$G'"; }
compose_line() { printf '      %s\n' "$1" >>"$G/orchestrators/compose/base/auth-api.yml"; }

@test "unset everywhere: GoTrue's default (86400) passes, silently" {
  check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test ".env.gotrue at 3600: fails and names the file and the value" {
  printf 'GOTRUE_MAILER_OTP_EXP=3600\n' >"$G/.env.gotrue"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == "GOTRUE_MAILER_OTP_EXP=3600 in .env.gotrue is below 86400 s"* ]]
}

@test ".env.gotrue boundary: 86400 passes, 86399 fails" {
  printf 'GOTRUE_MAILER_OTP_EXP=86400\n' >"$G/.env.gotrue"
  check
  [ "$status" -eq 0 ]
  printf 'GOTRUE_MAILER_OTP_EXP="86399"\n' >"$G/.env.gotrue"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=86399 in .env.gotrue"* ]]
}

@test "a second, lower line in .env.gotrue is not hidden by a first good one" {
  printf 'GOTRUE_MAILER_OTP_EXP=172800\nGOTRUE_MAILER_OTP_EXP=600\n' >"$G/.env.gotrue"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=600 in .env.gotrue"* ]]
}

@test "a value that is not a number of seconds fails" {
  printf 'GOTRUE_MAILER_OTP_EXP=24h\n' >"$G/.env.gotrue"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=24h in .env.gotrue is not a whole number of seconds"* ]]
}

@test "compose literal below the floor fails and names the compose file" {
  compose_line 'GOTRUE_MAILER_OTP_EXP: "600"'
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=600 in orchestrators/compose/base/auth-api.yml is below"* ]]
}

@test "compose list form below the floor fails" {
  printf 'services:\n  gotrue:\n    environment:\n      - GOTRUE_MAILER_OTP_EXP=900\n' >"$G/orchestrators/compose/overlays/prod.yml"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=900 in orchestrators/compose/overlays/prod.yml"* ]]
}

@test "compose \${VAR:-default}: the default is judged when .env is silent, .env when it speaks" {
  compose_line 'GOTRUE_MAILER_OTP_EXP: ${GOTRUE_MAILER_OTP_EXP:-3600}'
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=3600 in orchestrators/compose/base/auth-api.yml"* ]]
  printf 'GOTRUE_MAILER_OTP_EXP=90000\n' >>"$G/.env"
  check
  [ "$status" -eq 0 ]
}

@test "compose \${OTHER}: resolved through another .env name" {
  compose_line 'GOTRUE_MAILER_OTP_EXP: ${MAIL_TOKEN_TTL}'
  printf 'MAIL_TOKEN_TTL=7200\n' >>"$G/.env"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=7200 in orchestrators/compose/base/auth-api.yml"* ]]
}

@test "compose passthrough (KEY: with no value) reads the .env value" {
  compose_line 'GOTRUE_MAILER_OTP_EXP:'
  printf 'GOTRUE_MAILER_OTP_EXP=1800\n' >>"$G/.env"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=1800 in orchestrators/compose/base/auth-api.yml"* ]]
}

@test "a running mini-baas-gotrue started with 3600 fails even when every file is clean" {
  export FAKE_GOTRUE=1
  printf 'GOTRUE_MAILER_OTP_EXP=3600\n' >>"$FAKE_GOTRUE_ENV"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"=3600 in the running mini-baas-gotrue"* ]]
}

@test "a running mini-baas-gotrue without the key passes" {
  export FAKE_GOTRUE=1
  check
  [ "$status" -eq 0 ]
}
