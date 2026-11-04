# shellcheck shell=bash
# datacenter-models.sh — what make all may write to the VM's databases, and when: a verified dump
# before any schema change, and an owner re-stamp once per recorded seed.
# Sourced by scripts/datacenter.sh, which defines note, die, REPO, PG_CTN, MODELS, DUMP_DIR.
# Caveat: pg_restore reads the dump back but no schema or row is compared to the live database, so a
# dump can verify and still predate a write made while it ran (under-reports); make all holds no lock.

# The dump is taken before any DDL and read back in full by the same server's pg_restore: -l alone
# reads only the table of contents, so a truncated body would pass it. It covers the postgres
# database only, which is what models/*.sql writes.
dump_postgres() {
  local file listing
  file="$DUMP_DIR/postgres-$(date +%Y%m%d-%H%M%S).dump"
  (umask 077 && mkdir -p "$DUMP_DIR" && : >"$file")
  docker exec "$PG_CTN" pg_dump -U postgres -d postgres -Fc >"$file" || die "pg_dump failed; no migration ran"
  # Listed first, not piped: grep -q exits at its match, the writer takes SIGPIPE, and under
  # pipefail a good dump reads as a bad one (2026-11-04, this stopped a run on a dump that was fine).
  listing=$(docker exec -i "$PG_CTN" pg_restore -l <"$file") || die "the dump $file cannot be listed; no migration ran"
  grep -q 'TABLE DATA public osionos_pages' <<<"$listing" ||
    die "the dump $file does not list osionos_pages; no migration ran"
  docker exec -i "$PG_CTN" pg_restore -f /dev/null <"$file" >/dev/null 2>&1 ||
    die "the dump $file does not read back in full; no migration ran"
  note "verified dump: $file"
}

models_hash() { cat "$REPO"/models/*.sql | sha256sum | cut -d' ' -f1; }
applied_hash() {
  docker exec "$PG_CTN" psql -U postgres -d postgres -tA -c 'select sha from groot_meta.models_state' 2>/dev/null || true
}
# The marker travels with the data: a restore brings its own back, and the next run replays.
record_hash() {
  docker exec -i "$PG_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL || die "the models applied, but the marker could not be written"
CREATE SCHEMA IF NOT EXISTS groot_meta;
CREATE TABLE IF NOT EXISTS groot_meta.models_state (sha text NOT NULL);
TRUNCATE groot_meta.models_state;
INSERT INTO groot_meta.models_state VALUES ('$1');
SQL
}

# models_converge — the VM's schema against models/*.sql. A hash change also catches a migration
# that only adds a column, which the runner's table check cannot see. Armed realtime triggers come
# back after every grobase `up`, so they are routine and only their own file runs.
models_converge() {
  local out rc=0 sha
  sha=$(models_hash)
  out=$(sh "$MODELS" --check 2>&1) || rc=$?
  printf '%s\n' "$out" >&2
  ! grep -qE 'not running|query failed' <<<"$out" || die "the VM's postgres could not be read; nothing was written"
  if grep -q 'pending: ' <<<"$out" || [ "$(applied_hash)" != "$sha" ]; then
    require_writes "applying models/*.sql to the VM"
    dump_postgres
    sh "$MODELS" || die "the models migrations failed; the dump is in $DUMP_DIR"
    record_hash "$sha"
  elif [ "$rc" -ne 0 ]; then
    if ! writes_allowed; then
      note "realtime triggers are armed on the VM; make all from a terminal clears them"
      return 0
    fi
    docker exec -i "$PG_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      <"$REPO/models/realtime-cdc-off-migration.sql" >/dev/null || die "realtime-cdc-off failed"
  fi
  sh "$MODELS" --check ||
    die "the VM is still not converged. realtime-cdc-off gives each table 2 s, so a long reader such as the VM's hourly backup (at :15) can keep a trigger: run make all again"
}

# seed_id — the seed the VM records, whoever loaded it. Empty means no seed is on record.
seed_id() { vm_ssh "$ALIAS" 'cat /etc/b2b/seeds.last 2>/dev/null' 2>/dev/null | sed -n 's/^seeded_at=//p' | head -n 1; }
converged_seed() {
  docker exec "$PG_CTN" psql -U postgres -d postgres -tA -c 'select seeded_at from groot_meta.seed_state' 2>/dev/null || true
}
record_seed() {
  docker exec -i "$PG_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL || die "the key converged, but the marker could not be written"
CREATE SCHEMA IF NOT EXISTS groot_meta;
CREATE TABLE IF NOT EXISTS groot_meta.seed_state (seeded_at text NOT NULL);
TRUNCATE groot_meta.seed_state;
INSERT INTO groot_meta.seed_state VALUES ('$1');
SQL
}

# Once per recorded seed, by the owner's decision: a seed born2root loaded counts like one this run
# loaded, because its rows are known to be the seed's until the marker says this seed is converged.
# After that a mismatch stops, so rows users added are never re-stamped by a later run. The re-stamp
# writes five databases the dump does not cover (ADR 0003): a new seed restores them.
live_data_converge() {
  local seed
  seed=$(seed_id)
  if bash "$REPO/scripts/ensure-live-data-access.sh" --check; then
    [ -z "$seed" ] || [ "$(converged_seed)" = "$seed" ] || ! writes_allowed || record_seed "$seed"
    return 0
  fi
  if [ -z "$seed" ] || [ "$(converged_seed)" = "$seed" ]; then
    die "the app's key or the rows it owns need a repair, and no new seed explains it, so make all leaves them alone. Read ADR 0003, then: make link-live-data-ensure"
  fi
  require_writes "converging the key on the seeded rows"
  note "seed $seed has not been converged: moving its rows onto the app's key"
  bash "$REPO/scripts/ensure-live-data-access.sh" || die "the key could not be converged"
  bash "$REPO/scripts/ensure-live-data-access.sh" --check || die "the key still does not converge"
  record_seed "$seed"
}
