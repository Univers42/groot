#!/usr/bin/env sh
# seed-users.sh — creates N demo users (default 12) with the GoTrue admin API
# through the edge (POST /auth/v1/admin/users, service key, email_confirm:
# true). Emails: eval-user-NN@osionos.test. Random passwords are written to
# infrastructure/eval/.users (gitignored, mode 600) and are NEVER printed.
#
# TRUTHFUL AND IDEMPOTENT:
#   * the request body is written to a mode-600 file and sent with
#     --data-binary @file. The old version sent --data-binary @- and piped
#     NOTHING into it, so every create was an empty body;
#   * a NEW password reaches .users only AFTER GoTrue answered 200/201;
#   * a user that already exists (GoTrue answers 422) keeps the password
#     that is already in .users — the file is never rewritten with a password
#     GoTrue does not know;
#   * ANY other status fails the script.
# A response body is never printed.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/.env"
USERS_FILE="$HERE/.users"

NUM_USERS=${1:-12}

note() { printf '[seed-users] %s\n' "$*" >&2; }
die() { printf '[seed-users] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — run gen-secrets.sh first"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
[ -n "${SERVICE_ROLE_KEY:-}" ] || die "SERVICE_ROLE_KEY is not set in $ENV_FILE"

EDGE_PORT=${EVAL_EDGE_PORT:-18000}
BASE_URL="http://127.0.0.1:${EDGE_PORT}"

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
BODY_FILE="$TMP/body.json"
RESP_FILE="$TMP/resp"
umask 077

# The .users file: mode 600, never truncated (it holds the passwords).
touch "$USERS_FILE"
chmod 600 "$USERS_FILE"

gen_password() {
  out=""
  while [ "${#out}" -lt 16 ]; do
    out="${out}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "$out" | cut -c1-16
}

# The password already on file for an email, if any.
password_of() {
  awk -v want="$1:" 'index($0, want) == 1 { sub(/^[^:]*:/, ""); print; exit }' "$USERS_FILE"
}

created=0
existing=0
i=1
while [ "$i" -le "$NUM_USERS" ]; do
  email=$(printf 'eval-user-%02d@osionos.test' "$i")

  known=$(password_of "$email")
  if [ -n "$known" ]; then
    password=$known
  else
    password=$(gen_password)
  fi

  # The body goes to a file: a secret on a command line is a secret in the
  # process list, and --data-binary @- with nothing piped sends NOTHING.
  printf '{"email":"%s","password":"%s","email_confirm":true}' "$email" "$password" > "$BODY_FILE"
  chmod 600 "$BODY_FILE"

  code=$(curl -sS --max-time 20 -o "$RESP_FILE" -w '%{http_code}' \
    -X POST \
    -H "apikey: ${SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@${BODY_FILE}" \
    "${BASE_URL}/auth/v1/admin/users") || code=000

  case "$code" in
    200 | 201)
      if [ -z "$known" ]; then
        # Only now — after GoTrue accepted the user — does the password
        # become real.
        printf '%s:%s\n' "$email" "$password" >> "$USERS_FILE"
        created=$((created + 1))
      else
        existing=$((existing + 1))
      fi
      ;;
    422)
      if [ -z "$known" ]; then
        die "GoTrue says $email already exists (422) but $USERS_FILE has no password for it — restore the file or delete the user"
      fi
      # The user exists and .users holds its password: leave it alone.
      existing=$((existing + 1))
      ;;
    *)
      die "GoTrue answered HTTP $code for $email (the response body is not shown)"
      ;;
  esac
  i=$((i + 1))
done

note "seeded $NUM_USERS demo users ($created created, $existing already present)"
# Only the path — never a password.
echo "$USERS_FILE"
