#!/usr/bin/env bash
# account-mail.sh — pr1-pr6 on a throwaway local stack: every account mail, read back from Mailpit.
#
# Those specs skip on a default stack, because a default gateway neither verifies email nor asks
# for a sign-in code. This turns each on, recreates the gateway, and fails on any skip, since a
# green run that skipped proves nothing. tests/e2e/run.sh still decides whether the specs may run
# at all: it refuses a linked grobase, so this cannot reach the VM.
#
# Caveat: pr3's timing bound (50 ms between medians) is measured on whatever else the machine is
# doing; a loaded runner can fail it with no real leak, and only a rerun tells them apart.
# Caveat: the reset links live RESET_TTL_SEC here so PR2 can watch one expire; a stack slower than
# that between mail and click fails PR2's other tests.
set -euo pipefail
cd "$(dirname "$0")/../.."

RESET_TTL_SEC=30
LOG=tests/e2e/test-results/account-mail.log

recreate_gateway() {
  docker compose --env-file ./.env.local up -d --no-build --force-recreate --wait auth-gateway
}

# run_specs SPEC... — runs them, keeps the output, and refuses a run that skipped anything.
run_specs() {
  bash tests/e2e/run.sh "$@" 2>&1 | tee -a "$LOG" || return 1
  if tail -n 6 "$LOG" | grep -Eq '[0-9]+ skipped'; then
    echo "[account-mail] a spec skipped: this run proves nothing about it" >&2
    return 1
  fi
}

mkdir -p "$(dirname "$LOG")"
: >"$LOG"

export AUTH_REQUIRE_EMAIL_VERIFICATION=true PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION=true
export AUTH_RESET_TOKEN_TTL_SEC="$RESET_TTL_SEC" E2E_SHORT_RESET_TTL_SEC="$RESET_TTL_SEC"
failed=0
recreate_gateway
run_specs specs/pr1-signup-verify.spec.ts specs/pr2-reset.spec.ts \
  specs/pr3-no-enumeration.spec.ts specs/pr4-recover-cap.spec.ts specs/pr6-mail-burst.spec.ts || failed=1

# A failure above must not hide this group: it needs its own gateway, and it is the only proof
# of the emailed sign-in code.
export AUTH_LOGIN_EMAIL_OTP=true
recreate_gateway
run_specs specs/pr5-login-otp.spec.ts || failed=1
exit "$failed"
