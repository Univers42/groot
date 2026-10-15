#!/usr/bin/env bats
# scripts/lib/e2e-mail-guard.sh decides whether tests/e2e/run.sh may run the specs that send
# real mail (pr*, dm*): only when the running auth-gateway and GoTrue deliver to Mailpit and
# no link relay points at a remote backend (verdict B C11, C12). A stub docker answers from
# planted files: the gateway's environment is a temporary .env.local, GoTrue's another file.
# No daemon is touched. The last three tests drive tests/e2e/run.sh itself through the same stub.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash coreutils && bats scripts/tests/e2e-mail-guard.bats'

bats_require_minimum_version 1.5.0

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib/e2e-mail-guard.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export FAKE_GATEWAYS="track-binocle-auth-gateway-1"
  export FAKE_GOTRUE=1
  export FAKE_RELAY=""
  export FAKE_GATEWAY_ENV="$BATS_TEST_TMPDIR/.env.local"
  export FAKE_GOTRUE_ENV="$BATS_TEST_TMPDIR/gotrue.env"
  printf 'SMTP_HOST=mailpit\nSMTP_PASS=canary-secret-value\nSMTP_PORT=1025\n' >"$FAKE_GATEWAY_ENV"
  printf 'GOTRUE_SMTP_HOST=mailpit\nGOTRUE_SMTP_PASS=canary-secret-value\n' >"$FAKE_GOTRUE_ENV"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$GROBASE_LINK_DIR"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_LOG:-/dev/null}"
case "$1" in
ps)
  case "$*" in
  *service=auth-gateway*) for n in $FAKE_GATEWAYS; do echo "$n"; done ;;
  *service=grobase-link*) [ -z "$FAKE_RELAY" ] || echo "$FAKE_RELAY" ;;
  *mini-baas-gotrue*) [ -z "$FAKE_GOTRUE" ] || echo mini-baas-gotrue ;;
  esac
  ;;
inspect)
  for name; do :; done
  case "$name" in
  mini-baas-gotrue) cat "$FAKE_GOTRUE_ENV" ;;
  track-binocle-auth-gateway-2) cat "$FAKE_GATEWAY2_ENV" ;;
  *) cat "$FAKE_GATEWAY_ENV" ;;
  esac
  ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

guard() { run bash -c ". '$LIB' && e2e_mail_guard"; }
plant_gateway_host() { sed -i "s/^SMTP_HOST=.*/SMTP_HOST=$1/" "$FAKE_GATEWAY_ENV"; }
link_state() { printf 'mode=%s\ntarget=%s\n' "$1" "$2" >"$GROBASE_LINK_DIR/state"; }

@test "gateway and GoTrue on Mailpit, no link: allowed, silent" {
  guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SMTP_HOST=smtp.titan.email planted in the gateway's .env.local: refused, named, no secret printed" {
  plant_gateway_host smtp.titan.email
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"track-binocle-auth-gateway-1 sends mail through SMTP_HOST=smtp.titan.email, not Mailpit"* ]]
  [[ "$output" != *"canary-secret-value"* ]]
}

@test "the last SMTP_HOST in the container environment is the one judged" {
  printf 'SMTP_HOST=smtp.titan.email\n' >>"$FAKE_GATEWAY_ENV"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"smtp.titan.email"* ]]
}

@test "a host that only starts with a Mailpit name is refused" {
  plant_gateway_host mailpit.relay.example
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"mailpit.relay.example"* ]]
}

@test "mini-baas-mailpit counts as Mailpit" {
  plant_gateway_host mini-baas-mailpit
  guard
  [ "$status" -eq 0 ]
}

@test "an unset SMTP_HOST is refused" {
  sed -i '/^SMTP_HOST=/d' "$FAKE_GATEWAY_ENV"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMTP_HOST=<unset>"* ]]
}

@test "a second gateway on the real relay is refused even when the first is on Mailpit" {
  export FAKE_GATEWAYS="track-binocle-auth-gateway-1 track-binocle-auth-gateway-2"
  export FAKE_GATEWAY2_ENV="$BATS_TEST_TMPDIR/gw2.env"
  printf 'SMTP_HOST=smtp.titan.email\n' >"$FAKE_GATEWAY2_ENV"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"track-binocle-auth-gateway-2"* ]]
}

@test "no auth-gateway running: refused, the host cannot be proven" {
  export FAKE_GATEWAYS=""
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"no auth-gateway container runs"* ]]
}

@test "GoTrue on the real relay: refused, named, no secret printed" {
  sed -i 's/^GOTRUE_SMTP_HOST=.*/GOTRUE_SMTP_HOST=smtp.titan.email/' "$FAKE_GOTRUE_ENV"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"mini-baas-gotrue sends mail through GOTRUE_SMTP_HOST=smtp.titan.email"* ]]
  [[ "$output" != *"canary-secret-value"* ]]
}

@test "no mini-baas-gotrue on this daemon: refused, the backend is not local" {
  export FAKE_GOTRUE=""
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"mini-baas-gotrue does not run on this daemon"* ]]
}

@test "link in ssh mode: refused even though everything says Mailpit" {
  link_state ssh b2b
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"remote backend (ssh b2b)"* ]]
}

@test "link in direct mode: refused" {
  link_state direct https://kong.example
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"remote backend (direct https://kong.example)"* ]]
}

@test "link in local mode: allowed" {
  link_state local ""
  guard
  [ "$status" -eq 0 ]
}

@test "a running relay with no link state: refused" {
  export FAKE_RELAY="track-binocle-grobase-link-1"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"records no link mode"* ]]
}

@test "e2e_names_mail_specs: pr*/dm* spec paths and filters, not other specs or options" {
  run bash -c ". '$LIB' && e2e_names_mail_specs specs/pr1-sign-up.spec.ts"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB' && e2e_names_mail_specs -g title dm2"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB' && e2e_names_mail_specs specs/ac1-new-account.spec.ts -g pr1"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB' && e2e_names_mail_specs specs/ac1-new-account.spec.ts --project=chromium"
  [ "$status" -eq 1 ]
  run bash -c ". '$LIB' && e2e_names_mail_specs"
  [ "$status" -eq 1 ]
  run bash -c ". '$LIB' && e2e_names_mail_specs specs/print-settings.spec.ts"
  [ "$status" -eq 1 ]
}

# run.sh with the stub: a throwaway CA path, the demo password preset, every docker call logged.
run_e2e() {
  export LOCAL_CA_FILE="$BATS_TEST_TMPDIR/ca.pem" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" E2E_DEMO_PASSWORD=unused
  : >"$LOCAL_CA_FILE"
  run bash "$BATS_TEST_DIRNAME/../../tests/e2e/run.sh" "$@"
}

@test "run.sh: a named pr spec on the real relay is refused with exit 3, before any image build" {
  plant_gateway_host smtp.titan.email
  run_e2e specs/pr1-signup-verify.spec.ts
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing the pr*/dm* specs: track-binocle-auth-gateway-1 sends mail through SMTP_HOST=smtp.titan.email"* ]]
  run grep -c '^build' "$DOCKER_LOG"
  [ "$output" = 0 ]
}

@test "run.sh: a full run on the real relay skips the pr*/dm* specs and hands Playwright the reason" {
  plant_gateway_host smtp.titan.email
  run_e2e
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the pr*/dm* specs"* ]]
  grep '^run ' "$DOCKER_LOG" | grep -q -- '-e E2E_SKIP_MAIL_SPECS'
}

@test "run.sh: on Mailpit everywhere nothing is skipped" {
  run_e2e specs/pr1-signup-verify.spec.ts
  [ "$status" -eq 0 ]
  [[ "$output" != *"pr*/dm*"* ]]
  grep '^run ' "$DOCKER_LOG" | grep -q 'pr1-signup-verify'
  run grep -c -- 'E2E_SKIP_MAIL_SPECS' "$DOCKER_LOG"
  [ "$output" = 0 ]
}
