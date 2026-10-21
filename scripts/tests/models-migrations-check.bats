#!/usr/bin/env bats
# `apply-models-migrations.sh --check` matched CREATE TABLE with gawk's IGNORECASE, which
# mawk (Debian's awk, and this runner's) ignores: an upper-case `CREATE TABLE IF NOT EXISTS
# public.auth_session_cutoffs` was never seen, --check said "converged" on baas while the
# table was missing, and the bridge answered 503 to every session (2026-10-21). docker is a
# stub: `ps` names the postgres container, and a table probe answers 1 only for $PRESENT.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/models-migrations-check.bats

bats_require_minimum_version 1.5.0

setup() {
  export MODELS_DIR="$BATS_TEST_TMPDIR/models" PRESENT=""
  mkdir -p "$MODELS_DIR" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
ps) printf 'mini-baas-postgres\n' ;;
exec) for t in $PRESENT; do
    case "$*" in *"table_name='$t'"*) printf '1\n'; exit 0 ;; esac
  done ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  # Pin the awk that hid the gap when this image has it; gawk would pass either way.
  if command -v mawk >/dev/null 2>&1; then ln -s "$(command -v mawk)" "$BATS_TEST_TMPDIR/bin/awk"; fi
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "an upper-case CREATE TABLE that is missing is reported pending" {
  printf 'CREATE TABLE IF NOT EXISTS public.auth_session_cutoffs (user_id uuid);\n' \
    >"$MODELS_DIR/auth-session-cutoffs.sql"
  run -1 sh "$BATS_TEST_DIRNAME/../apply-models-migrations.sh" --check
  [[ "$output" == *"pending: auth-session-cutoffs.sql (missing table: auth_session_cutoffs)"* ]]
}

@test "the same file is converged once the table exists" {
  printf 'CREATE TABLE IF NOT EXISTS public.auth_session_cutoffs (user_id uuid);\n' \
    >"$MODELS_DIR/auth-session-cutoffs.sql"
  PRESENT=auth_session_cutoffs run -0 sh "$BATS_TEST_DIRNAME/../apply-models-migrations.sh" --check
  [[ "$output" == *"converged"* ]]
}

@test "lower-case and mixed-case DDL name the table the same way" {
  printf 'create table osionos_a (id int);\nCreate Table If Not Exists Public.Osionos_B (id int);\n' \
    >"$MODELS_DIR/mixed.sql"
  PRESENT=osionos_a run -1 sh "$BATS_TEST_DIRNAME/../apply-models-migrations.sh" --check
  [[ "$output" == *"(missing table: osionos_b)"* ]]
}

@test "a CREATE TABLE named in a comment is not a pending table" {
  printf -- "-- realtime trigger grobase's CREATE TABLE hook gives it.\nCREATE TABLE IF NOT EXISTS public.auth_session_cutoffs (user_id uuid); -- create table not_this\n" \
    >"$MODELS_DIR/auth-session-cutoffs.sql"
  PRESENT=auth_session_cutoffs run -0 sh "$BATS_TEST_DIRNAME/../apply-models-migrations.sh" --check
  [[ "$output" == *"converged"* ]]
}
