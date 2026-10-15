#!/usr/bin/env bash
# Runs the suite in the pinned Playwright container against the live local stack.
# --network host so https://localhost:3001/:3007 resolve to the host's proxy; --rm so no
# container (and no Chromium) outlives the run.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image="${E2E_IMAGE:-groot-e2e:1.63.0}"
# shellcheck source=scripts/lib/docker-run.sh
. "$root/scripts/lib/docker-run.sh"
ca="$(local_ca_file "$root")" || { echo "[e2e] no local CA under $root (or LOCAL_CA_FILE) — run: make certs" >&2; exit 2; }
# The pr*/dm* specs send real mail and create accounts. They run only on a backend on this
# daemon whose auth-gateway and GoTrue both mail Mailpit (verdict B C11, C12) and whose GoTrue
# keeps a confirmation token for the 24 h the link lives (C14). Named on the command line, a
# refusal stops the run (exit 3); in a full run those specs are skipped and the reason printed.
# shellcheck source=scripts/lib/e2e-mail-guard.sh
. "$root/scripts/lib/e2e-mail-guard.sh"
# shellcheck source=scripts/lib/gotrue-otp-exp.sh
. "$root/scripts/lib/gotrue-otp-exp.sh"
mail_refusal="$(e2e_mail_guard)" || mail_refusal="${mail_refusal:-the e2e mail guard failed}"
if [[ -z "$mail_refusal" ]]; then
  mail_refusal="$(gotrue_otp_exp_check "$root/apps/grobase")" || mail_refusal="${mail_refusal:-the GoTrue OTP expiry preflight failed}"
fi
if [[ -n "$mail_refusal" ]]; then
  if e2e_names_mail_specs "$@"; then
    echo "[e2e] refusing the pr*/dm* specs: $mail_refusal" >&2
    exit 3
  fi
  export E2E_SKIP_MAIL_SPECS="$mail_refusal"
  echo "[e2e] skipping the pr*/dm* specs: $mail_refusal" >&2
elif [[ -z "${E2E_KONG_ANON_KEY:-}" ]]; then
  # The public anon key Kong asks of the TOTP enrolment in pr2 (not a secret: it is in every bundle).
  # shellcheck source=scripts/lib/envfile.sh
  . "$root/scripts/lib/envfile.sh"
  if E2E_KONG_ANON_KEY="$(get_env "$root/.env.local" KONG_PUBLIC_API_KEY)"; then
    export E2E_KONG_ANON_KEY
  else
    unset E2E_KONG_ANON_KEY
  fi
fi
docker build -q -t "$image" "$here" >/dev/null
mkdir -p "$here/test-results"
# The demo account owns the workspaces the live databases are mounted on (DB1, DB2). Its
# password is minted per machine into ./.env.local; demo-login.sh is its one reader. Absent,
# those specs skip and say why.
if [[ -z "${E2E_DEMO_PASSWORD:-}" ]]; then
  # shellcheck source=scripts/lib/demo-login.sh
  . "$root/scripts/lib/demo-login.sh"
  if E2E_DEMO_PASSWORD="$(demo_login_password "$root/.env.local" 2>/dev/null)"; then
    export E2E_DEMO_PASSWORD E2E_DEMO_EMAIL="${E2E_DEMO_EMAIL:-$DEMO_LOGIN_EMAIL}"
  else
    unset E2E_DEMO_PASSWORD
  fi
fi
env_args=()
while IFS= read -r name; do env_args+=(-e "$name"); done < <(compgen -e | grep '^E2E_' || true)
mapfile -t user_args < <(docker_run_user_args)
# The sources, read-only over the image's /e2e (which keeps its own node_modules). A config here
# is picked with `-c`, e.g. `run.sh -c site-audit.config.ts` (scripts/site-audit.sh).
src_args=()
for path in specs lib site-audit playwright.config.ts site-audit.config.ts tsconfig.json; do
  src_args+=(-v "$here/$path:/e2e/$path:ro")
done
exec docker run --rm -e NPM_CONFIG_UPDATE_NOTIFIER=false --init --network host --ipc host \
  "${user_args[@]}" -e HOME=/tmp/e2e-home \
  "${env_args[@]}" \
  -v "$ca:/certs/local-ca.pem:ro" \
  "${src_args[@]}" \
  -v "$here/test-results:/e2e/test-results" \
  "$image" sh -c 'npx tsc -p tsconfig.json && npx playwright test "$@"' sh "$@"
