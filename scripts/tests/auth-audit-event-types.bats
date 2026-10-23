#!/usr/bin/env bats
# The auth gateway (apps/opposite-osiris) writes audit events through auth_record_audit_event,
# and models/auth-security-migration.sql holds the only list of event types the table accepts.
# A type the gateway writes but the list lacks is refused at runtime: the event is lost and the
# request carries on, so nothing but this test notices. Measured 2026-10-19: 35 types refused.
#
# The writers are read from ${OSIRIS_SRC:-apps/opposite-osiris} by lib/audit-event-writers.sh.
# The submodule pin is far behind the gateway main, so OSIRIS_SRC=<export of a newer commit>
# is the way to test a gateway that has not been pinned yet. Without the source the suite SKIPs
# locally and FAILS under CI=true (the restore-gate-tests job passes `-e CI` into the container).
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache coreutils findutils git jq make && bats scripts/tests/auth-audit-event-types.bats'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SQL="$REPO/models/auth-security-migration.sql"
  WRITERS="$BATS_TEST_DIRNAME/lib/audit-event-writers.sh"
  SRC=${OSIRIS_SRC:-$REPO/apps/opposite-osiris}
}

require_source() {
  [ -f "$SRC/scripts/auth-gateway.mjs" ] && return 0
  [ "${CI:-}" != true ] || fail "CI=true and no gateway source at $SRC (is apps/opposite-osiris checked out?)"
  skip "no gateway source at $SRC"
}

# Fails the test with $1 as the reason.
fail() {
  echo "$1" >&2
  return 1
}

# The lines between `CHECK (event_type IN (` and the closing `));`, exactly as written.
check_list_lines() {
  awk '/ADD CONSTRAINT auth_audit_events_event_type_check CHECK \(event_type IN \($/ { in_list = 1; next }
       in_list && /^  \)\);$/ { exit }
       in_list' "$SQL"
}

check_list() { check_list_lines | tr -d "', " | sort -u; }

# Writers of the source tree $1 that the CHECK list does not accept.
unlisted_writers() {
  sh "$WRITERS" "$1" | comm -23 - <(check_list)
}

# A copy of the gateway scripts in $BATS_TEST_TMPDIR/src that a test can add a call to.
copy_source() {
  mkdir -p "$BATS_TEST_TMPDIR/src"
  cp -r "$SRC/scripts" "$BATS_TEST_TMPDIR/src/"
  FIXTURE="$BATS_TEST_TMPDIR/src"
}

@test "every audit event type the gateway writes is in the CHECK list" {
  require_source
  run unlisted_writers "$SRC"
  echo "writers missing from the list: $output"
  [ -z "$output" ]
}

@test "the extractor sees the writers (a silent extractor would pass the test above vacuously)" {
  require_source
  run sh "$WRITERS" "$SRC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 20 ]
  [[ "$output" == *login_success* ]]
  [[ "$output" == *register_turnstile_failed* ]]
}

@test "the CHECK list is well formed: one quoted name per line, a comma after all but the last" {
  last=$(check_list_lines | tail -n 1)
  bad_items=$(check_list_lines | head -n -1 | grep -vE "^ +'[a-z_]+',$" || true)
  [ -z "$bad_items" ] || fail "item without exactly one name and a trailing comma: $bad_items"
  [[ "$last" =~ ^\ +\'[a-z_]+\'$ ]] || fail "last item must be one name with no comma: $last"
  [ "$(check_list_lines | wc -l)" -gt 36 ]
}

@test "the CHECK list has no duplicate name" {
  duplicates=$(check_list_lines | tr -d "', " | sort | uniq -d)
  [ -z "$duplicates" ] || fail "listed twice: $duplicates"
}

@test "auth_record_audit_event keeps no list of its own" {
  run sed -n '/CREATE OR REPLACE FUNCTION auth_record_audit_event/,/^\$\$;/p' "$SQL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSERT INTO auth_audit_events"* ]]
  [[ "$output" != *"NOT IN ("* ]]
  [[ "$output" == *"ERRCODE = '22023'"* ]]
}

@test "a flowAudit call with an unlisted literal is reported" {
  require_source
  copy_source
  echo "flowAudit('zz_probe', {});" >>"$FIXTURE/scripts/auth-gateway.mjs"
  run unlisted_writers "$FIXTURE"
  [ "$output" = zz_probe ]
}

@test "a revoke(record, 'x') with an unlisted name is reported" {
  require_source
  copy_source
  echo "await revoke(record, 'zz_probe2');" >>"$FIXTURE/scripts/auth/login-otp.mjs"
  run unlisted_writers "$FIXTURE"
  [ "$output" = zz_probe2 ]
}

@test "a new protectedAction is expanded to its _turnstile_failed event" {
  require_source
  copy_source
  echo "await protectedAction(request, response, 'zzaction', async () => {});" >>"$FIXTURE/scripts/auth-gateway.mjs"
  run unlisted_writers "$FIXTURE"
  [ "$output" = zzaction_turnstile_failed ]
}

@test "sendMessage, signedLink and a ternary inside audit() are reported" {
  require_source
  copy_source
  {
    echo "sendMessage(email, 'x', {}, 'zz_send');"
    echo "signedLink('signup', email, result, 'zz_link');"
    echo "audit(ok ? 'zz_yes' : 'zz_no', {});"
    echo "const mode = ok ? 'zz_not_audit' : 'zz_not_audit2';"
  } >>"$FIXTURE/scripts/auth/account-mail.mjs"
  run unlisted_writers "$FIXTURE"
  [ "$output" = "$(printf 'zz_link\nzz_no\nzz_send\nzz_yes')" ]
}
