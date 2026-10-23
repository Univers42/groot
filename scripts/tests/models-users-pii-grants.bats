#!/usr/bin/env bats
# Static guard for devil ML-7 (ADR 0014): no models/*.sql may grant public.users.email to anon,
# nor password_hash to anyone. A GRANT in these files is replayed by `make apply-models` and
# `make models-migrate`, so one bad line re-opens the leak on every boot.
#
# Caveat: line-based grep. A GRANT whose column list is wrapped across lines, or built with
# format()/EXECUTE, is not seen; users-pii-grants-migration.sql builds its lists that way and the
# live proof is `make models-grants-verify` (check u).
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils findutils git jq && bats scripts/tests/models-users-pii-grants.bats'

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  MODELS="$REPO/models"
}

# Lines granting password_hash to any role.
grants_password_hash() { grep -inE 'grant .*password_hash' "$1"/*.sql; }

# Lines granting email to anon on users.
grants_anon_email() { grep -inE 'grant .*\bemail\b.* on (table )?(public\.)?users to .*\banon\b' "$1"/*.sql; }

@test "no models file grants users.password_hash" {
  run ! grants_password_hash "$MODELS"
}

@test "no models file grants users.email to anon" {
  run ! grants_anon_email "$MODELS"
}

@test "the detector sees a planted password_hash grant" {
  mkdir "$BATS_TEST_TMPDIR/m"
  echo 'GRANT SELECT (id, password_hash) ON users TO authenticated;' >"$BATS_TEST_TMPDIR/m/x.sql"
  run grants_password_hash "$BATS_TEST_TMPDIR/m"
  [ "$status" -eq 0 ]
}

@test "the detector sees the old gdpr anon email grant" {
  mkdir "$BATS_TEST_TMPDIR/m"
  echo 'GRANT SELECT (id, username, email, avatar_url) ON users TO anon;' >"$BATS_TEST_TMPDIR/m/x.sql"
  run grants_anon_email "$BATS_TEST_TMPDIR/m"
  [ "$status" -eq 0 ]
}

@test "ORDERED_LAST ends with the users grants migration" {
  run grep -E '^ORDERED_LAST=".* users-pii-grants-migration\.sql"$' "$REPO/scripts/apply-models-migrations.sh"
  [ "$status" -eq 0 ]
}

# apply-models.sh's own order, under the collation that broke it and under C.
order_last() { LC_ALL=$1 MODELS_DIR=$2 sh "$REPO/scripts/apply-models.sh" order | tail -1; }

@test "apply-models.sh runs the users grants migration last, whatever the locale" {
  mkdir "$BATS_TEST_TMPDIR/m"
  : >"$BATS_TEST_TMPDIR/m/user.sql"
  : >"$BATS_TEST_TMPDIR/m/zzz.sql"
  : >"$BATS_TEST_TMPDIR/m/users-pii-grants-migration.sql"
  for loc in C en_US.UTF-8; do
    run order_last "$loc" "$BATS_TEST_TMPDIR/m"
    [ "$output" = "$BATS_TEST_TMPDIR/m/users-pii-grants-migration.sql" ]
  done
  run order_last C "$REPO/models"
  [ "$output" = "$REPO/models/users-pii-grants-migration.sql" ]
}
