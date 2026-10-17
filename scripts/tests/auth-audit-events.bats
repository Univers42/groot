#!/usr/bin/env bats
# The auth-gateway audits through public.auth_record_audit_event(), and models/auth-audit-events-migration.sql
# holds the one CHECK list that decides which events are accepted. A gateway event missing from
# the list is refused at runtime and swallowed by audit()'s catch, so the trail loses it without
# a failure anywhere. This reads the event names out of the gateway's source and asserts each is
# in the list.
#
# Caveat: the extraction is a regex, not a parser. It reads (audit|flowAudit)( first arguments
# that are quoted literals, ternaries of them, or a template whose only substitution is
# ${action} (expanded over the protectedAction(...) names), plus the last quoted argument of
# sendMessage( / signedLink( calls. An event name built any other way is reported as
# "<dynamic ...>" and fails the test (over-reporting, the safe direction); a call spread over
# two lines before its first comma is not seen (under-reporting).
#
# Needs apps/opposite-osiris checked out, or AUDIT_GATEWAY_DIR pointing at its scripts/ directory.
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#   -c 'apk add -q --no-cache bash coreutils && bats scripts/tests/auth-audit-events.bats'

setup() {
  MIGRATION="${AUDIT_MIGRATION:-$BATS_TEST_DIRNAME/../../models/auth-audit-events-migration.sql}"
  GATEWAY_DIR="${AUDIT_GATEWAY_DIR:-$BATS_TEST_DIRNAME/../../apps/opposite-osiris/scripts}"
}

# allowed_events MIGRATION — the CHECK list, one name per line.
allowed_events() {
  sed -n "/CHECK (event_type IN (/,/));/p" "$1" | grep -oE "'[a-z_]+'" | tr -d "'"
}

# mjs_grep DIR GREP_ARGS... — grep over every .mjs under DIR (busybox grep has no --include).
mjs_grep() {
  local dir="$1"
  shift
  find "$dir" -name '*.mjs' -exec grep -h "$@" {} +
}

# gateway_events DIR — every audit event name the sources under DIR emit, one per line.
gateway_events() {
  local dir="$1" actions tok name action
  actions="$(mjs_grep "$dir" -oE "protectedAction\(request, response, '[a-z_]+'" | grep -oE "'[a-z_]+'$" | tr -d "'")"
  {
    mjs_grep "$dir" -oE "(audit|flowAudit)\([^,)]*" | grep -oE "'[a-z_]+'|\`[^\`]*\`"
    mjs_grep "$dir" -E "(sendMessage|signedLink)\(" | sed -nE "s/.*'([a-z_]+)'\)+.*/'\1'/p"
  } | sort -u | while IFS= read -r tok; do
    case "$tok" in
    \`*\${action}*)
      name="${tok:1:${#tok}-2}"
      for action in $actions; do printf '%s\n' "${name//\$\{action\}/$action}"; done
      ;;
    \`*) printf '<dynamic %s>\n' "$tok" ;;
    *) printf '%s\n' "${tok//\'/}" ;;
    esac
  done | sort -u
}

# missing_events DIR MIGRATION — the gateway's events the CHECK list lacks.
missing_events() {
  comm -23 <(gateway_events "$1") <(allowed_events "$2" | sort -u)
}

# A gateway tree with one of each call shape the extractor handles.
fixture_gateway() {
  FIX="$BATS_TEST_TMPDIR/gw"
  mkdir -p "$FIX/auth"
  cat >"$FIX/gateway.mjs" <<'JS'
await audit('login_failed', request, {});
await audit(result.ok ? 'login_success' : 'login_failed', request, {});
await audit(`${action}_turnstile_failed`, request, {});
await protectedAction(request, response, 'recover', async () => {});
flowAudit('mail_job_failed', {});
JS
  cat >"$FIX/auth/mail.mjs" <<'JS'
audit('logout', {});
if (url) await sendMessage(email, 'resetPassword', {}, 'password_recovery_email_sent');
const u = signedLink('signup', email, result, 'register_failed');
JS
}

@test "the migration's CHECK list has no duplicate and carries the OTP and old-file events" {
  run allowed_events "$MIGRATION"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s\n' "$output" | sort | uniq -d)" ]
  for e in login_otp_requested login_otp_request_failed login_otp_verified login_otp_failed login_otp_expired login_otp_locked login_email_unconfirmed \
    register_requested ip_shift_detected webauthn_challenge_started newsletter_unsubscribe_email_failed; do
    printf '%s\n' "$output" | grep -qx "$e"
  done
}

@test "the function repeats no event list: the CHECK is the only one" {
  run grep -c "NOT IN" "$MIGRATION"
  [ "$output" = 0 ]
}

@test "extractor: literal, ternary, \${action} template, sendMessage and signedLink names are all found" {
  fixture_gateway
  run gateway_events "$FIX"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' login_failed login_success logout mail_job_failed password_recovery_email_sent recover_turnstile_failed register_failed | sort)" ]
}

@test "the fixture's events are all in the real CHECK list" {
  fixture_gateway
  run missing_events "$FIX" "$MIGRATION"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a planted unknown literal is reported" {
  fixture_gateway
  printf "await audit('planted_unknown_event', request, {});\n" >>"$FIX/gateway.mjs"
  run missing_events "$FIX" "$MIGRATION"
  [ "$output" = planted_unknown_event ]
}

@test "a planted unknown ternary branch, template action, sendMessage and signedLink name are reported" {
  fixture_gateway
  printf "audit(ok ? 'login_success' : 'planted_ternary', {});\n" >>"$FIX/auth/mail.mjs"
  printf "await protectedAction(request, response, 'planted_action', async () => {});\n" >>"$FIX/gateway.mjs"
  printf "sendMessage(e, 'x', {}, 'planted_message');\nsignedLink('t', e, r, 'planted_link');\n" >>"$FIX/auth/mail.mjs"
  run missing_events "$FIX" "$MIGRATION"
  [ "$output" = "$(printf '%s\n' planted_action_turnstile_failed planted_link planted_message planted_ternary)" ]
}

@test "a template with another substitution is reported as dynamic, not skipped" {
  fixture_gateway
  printf 'await audit(`${other}_failed`, request, {});\n' >>"$FIX/gateway.mjs"
  run missing_events "$FIX" "$MIGRATION"
  [[ "$output" == "<dynamic "* ]]
}

@test "every event the gateway emits is in the migration's CHECK list" {
  [ -d "$GATEWAY_DIR" ] || skip "no gateway sources at $GATEWAY_DIR: init apps/opposite-osiris or set AUDIT_GATEWAY_DIR"
  run gateway_events "$GATEWAY_DIR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 20 ]
  run missing_events "$GATEWAY_DIR" "$MIGRATION"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
