#!/usr/bin/env bats
# restore-if-empty.sh decides whether `make all` loads data OVER the running engines. It
# must only do so when the stack is provably fresh; it prefers the vault seeds in ./secrets
# (newest, all engines) over the committed git snapshot, and it must never accept a
# half-finished vault restore as "data present". These tests run a copy of the script
# against a fake `docker` and two stub restores that only record that they ran.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests

SEED_FILES="postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb"

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/apps/grobase/data-snapshots" "$ROOT/apps/grobase/scripts/ops" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../restore-if-empty.sh" "$ROOT/scripts/"
  GIT_RESTORED="$BATS_TEST_TMPDIR/git-restored"
  VAULT_RESTORED="$BATS_TEST_TMPDIR/vault-restored"
  printf '#!/bin/sh\ntouch "%s"\n' "$GIT_RESTORED" > "$ROOT/apps/grobase/data-snapshots/restore-databases.sh"
  chmod +x "$ROOT/apps/grobase/data-snapshots/restore-databases.sh"
  printf '#!/bin/sh\necho "EDITION=$EDITION SEED_DIR=$SEED_DIR" > "%s"\nexit "${VR_EXIT:-0}"\n' "$VAULT_RESTORED" \
    > "$ROOT/apps/grobase/scripts/ops/vault-restore.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  MARKER="$XDG_STATE_HOME/groot/restore-in-progress"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'FAKE'
#!/bin/sh
# Fake docker: RUNNING lists the containers that are up; PG_PAGES is osionos_pages' row count.
case "$1" in
  ps) for c in $RUNNING; do echo "$c"; done ;;
  inspect) echo healthy ;;
  restart) : ;;
  exec)
    case "$*" in
      *pg_isready*) exit 0 ;;
      *to_regclass*) echo t ;;
      *osionos_pages*) echo "$PG_PAGES" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# seeds [skip-in-sums]: write the engine dumps + an unrelated archive, then SHA256SUMS.
seeds() {
  mkdir -p "$ROOT/secrets"
  for f in $SEED_FILES inception-wordpress.tar.gz; do printf '%s' "$f" > "$ROOT/secrets/$f"; done
  (cd "$ROOT/secrets" && sha256sum $SEED_FILES inception-wordpress.tar.gz | grep -v " ${1:-none}\$" > SHA256SUMS)
}

run_script() { RUNNING="${RUNNING-mini-baas-postgres}" PG_PAGES="${PG_PAGES:-0}" run sh "$ROOT/scripts/restore-if-empty.sh"; }

@test "a fresh machine without vault seeds gets the git snapshot" {
  run_script
  [ "$status" -eq 0 ]
  [ -e "$GIT_RESTORED" ]
  [ ! -e "$VAULT_RESTORED" ]
}

@test "a populated postgres is never overwritten" {
  seeds
  PG_PAGES=364 run_script
  [ "$status" -eq 0 ]
  [ ! -e "$GIT_RESTORED" ] && [ ! -e "$VAULT_RESTORED" ]
}

@test "postgres not running is not proof of an empty stack" {
  seeds
  RUNNING="" run_script
  [ "$status" -eq 0 ]
  [ ! -e "$GIT_RESTORED" ] && [ ! -e "$VAULT_RESTORED" ]
  [[ "$output" == *"postgres"* ]]
}

@test "a fresh machine with verified vault seeds restores them, in the caller's edition" {
  seeds
  GROBASE_EDITION=migrate run_script
  [ "$status" -eq 0 ]
  [ ! -e "$GIT_RESTORED" ]
  grep -q "EDITION=migrate SEED_DIR=$ROOT/secrets" "$VAULT_RESTORED"
  [ ! -e "$MARKER" ]
}

@test "an unrelated file with a bad checksum does not block the vault restore" {
  seeds
  printf 'changed' > "$ROOT/secrets/inception-wordpress.tar.gz"
  run_script
  [ "$status" -eq 0 ]
  [ -e "$VAULT_RESTORED" ]
}

@test "a corrupt engine seed restores nothing and fails" {
  seeds
  printf 'corrupt' > "$ROOT/secrets/postgres-all.sql.gz"
  run_script
  [ "$status" -ne 0 ]
  [ ! -e "$GIT_RESTORED" ] && [ ! -e "$VAULT_RESTORED" ]
}

@test "an engine seed missing from SHA256SUMS restores nothing and fails" {
  seeds mongo.archive.gz
  run_script
  [ "$status" -ne 0 ]
  [ ! -e "$GIT_RESTORED" ] && [ ! -e "$VAULT_RESTORED" ]
}

@test "a failed vault restore fails make all, never falls back, and leaves the marker" {
  seeds
  VR_EXIT=3 run_script
  [ "$status" -ne 0 ]
  [ -e "$VAULT_RESTORED" ]
  [ ! -e "$GIT_RESTORED" ]
  [ -e "$MARKER" ]
}

@test "an unfinished vault restore is not mistaken for data on the next run" {
  seeds
  mkdir -p "$(dirname "$MARKER")" && echo "started" > "$MARKER"
  PG_PAGES=364 run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"make vault-restore"* ]]
  [ ! -e "$GIT_RESTORED" ] && [ ! -e "$VAULT_RESTORED" ]
}
