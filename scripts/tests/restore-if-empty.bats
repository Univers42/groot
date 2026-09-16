#!/usr/bin/env bats
# restore-if-empty.sh decides whether `make all` loads the committed snapshot OVER the running
# engines. It must only do so when the stack is provably fresh. These tests run a copy of the
# script against a fake `docker` and a stub restore that only records that it was called.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/apps/grobase/data-snapshots" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../restore-if-empty.sh" "$ROOT/scripts/"
  RESTORED="$BATS_TEST_TMPDIR/restored"
  printf '#!/bin/sh\ntouch "%s"\n' "$RESTORED" > "$ROOT/apps/grobase/data-snapshots/restore-databases.sh"
  chmod +x "$ROOT/apps/grobase/data-snapshots/restore-databases.sh"
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

@test "a fresh machine (postgres up and empty) gets the snapshot" {
  RUNNING="mini-baas-postgres" PG_PAGES=0 run sh "$ROOT/scripts/restore-if-empty.sh"
  [ "$status" -eq 0 ]
  [ -e "$RESTORED" ]
}

@test "a populated postgres is never overwritten" {
  RUNNING="mini-baas-postgres" PG_PAGES=364 run sh "$ROOT/scripts/restore-if-empty.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$RESTORED" ]
}

@test "postgres not running is not proof of an empty stack" {
  RUNNING="" PG_PAGES=0 run sh "$ROOT/scripts/restore-if-empty.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$RESTORED" ]
  [[ "$output" == *"postgres"* ]]
}
