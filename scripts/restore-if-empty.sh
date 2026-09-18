#!/usr/bin/env sh
# restore-if-empty.sh — load the all-engine data when the stack is genuinely fresh: every
# RUNNING primary engine (postgres osionos, mysql ops, mongo activity) is CONFIRMED empty.
# FAIL-SAFE: an engine with data aborts the restore — it never wipes a populated stack.
# The source is the 42ctl vault seeds in ./secrets when they are on disk (pulled by
# `make all`'s secrets-ensure: newest data, all 7 engines), else the committed git snapshot.
# grobase `up` is DETACHED (no --wait), so on a fresh machine the engines are still booting
# when we arrive; we WAIT for docker health first, otherwise a transient "not ready" is
# misread as "uncertain" and the restore is WRONGLY skipped (the bug that left a fresh
# machine with no data). A populated engine is healthy at once, so the no-wipe path is never
# delayed. Wired into `make all` (and `make bootstrap`).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE="$REPO/apps/grobase/data-snapshots/restore-databases.sh"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
note() { printf '[restore-if-empty] %s\n' "$1" >&2; }
numeric() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

# wait_healthy <container>: block until docker reports the engine healthy, or give up after
# ~180s. An engine with no healthcheck returns at once (nothing to wait on).
wait_healthy() {
  c="$1"
  running "$c" || return 0
  i=0
  while [ "$i" -lt 90 ]; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
    case "$st" in healthy | none) return 0 ;; esac
    i=$((i + 1))
    sleep 2
  done
  note "$c still not healthy after 180s — probe may read it as uncertain"
}

SEEDS="$REPO/secrets"
MANIFEST="$REPO/apps/grobase/data-snapshots/archives/MANIFEST.json"

# snapshot_vintage: when the git-committed archive was taken. A restore that does not say
# how old its data is cannot be told apart from a restore of the right data.
snapshot_vintage() {
  [ -f "$MANIFEST" ] || { printf 'unknown'; return 0; }
  v=$(sed -n 's/.*"created_utc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
  printf '%s' "${v:-unknown}"
}

STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
MARKER="$STATE_BASE/groot/restore-in-progress"
VAULT_RESTORE="$REPO/apps/grobase/scripts/ops/vault-restore.sh"
VAULT_BACKUPS="$STATE_BASE/grobase/vault-restore"
ENGINE_SEEDS="postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb"
OPTIONAL_SEEDS="dynamodb-all.tar.gz mssql-all.tar.gz"

# refuse_unfinished_restore: a vault restore that died half-way leaves postgres restored and
# the other engines empty. The next run would read postgres's rows as "data present" and
# never finish the job, so the marker (kept outside the repo) makes this run stop and say so.
refuse_unfinished_restore() {
  [ -e "$MARKER" ] || return 0
  note "a vault restore started ($(cat "$MARKER" 2>/dev/null)) and never finished — engines may be half-restored."
  note "  resume it:              make vault-restore"
  note "  pre-restore backups:    $VAULT_BACKUPS"
  note "  when resolved, remove:  $MARKER"
  exit 1
}

# vault_seeds_present: any engine dump in ./secrets means the vault is the source of truth.
vault_seeds_present() {
  for f in $ENGINE_SEEDS; do [ -f "$SEEDS/$f" ] && return 0; done
  return 1
}

# verify_seeds: every dump the restore will replay (the optional engines only when present)
# is listed in SHA256SUMS and matches it. Other files in ./secrets never block the restore.
verify_seeds() {
  [ -f "$SEEDS/SHA256SUMS" ] || { note "./secrets has no SHA256SUMS"; return 1; }
  needed="$ENGINE_SEEDS"
  for f in $OPTIONAL_SEEDS; do [ -f "$SEEDS/$f" ] && needed="$needed $f"; done
  sums=$(awk -v want=" $needed " '{ n = $2; sub(/^\*/, "", n) } index(want, " " n " ") { print; seen[n] = 1 }
    END { split(want, w, " "); for (i in w) if (w[i] != "" && !(w[i] in seen)) { print "MISSING " w[i] > "/dev/stderr"; bad = 1 } exit bad }' \
    "$SEEDS/SHA256SUMS") || { note "a seed the restore needs is not listed in SHA256SUMS"; return 1; }
  (cd "$SEEDS" && printf '%s\n' "$sums" | sha256sum -c >/dev/null 2>&1) || { note "a vault seed does not match SHA256SUMS"; return 1; }
}

# restore_from_vault: replay the verified seeds through vault-restore.sh in the caller's
# edition. A failure stops `make all` — never a fallback to the older git snapshot over a
# half-restored stack — and keeps the marker so the next run cannot call it done.
restore_from_vault() {
  verify_seeds || { note "vault seeds failed verification — nothing was restored"; exit 1; }
  mkdir -p "$(dirname "$MARKER")"
  printf '%s, seeds %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sha256sum "$SEEDS/SHA256SUMS" | cut -c1-16)" > "$MARKER"
  note "all running primary engines empty → restoring the vault seeds in ./secrets (all engines)…"
  if ! EDITION="${GROBASE_EDITION:-devlean}" SEED_DIR="$SEEDS" sh "$VAULT_RESTORE"; then
    note "vault restore FAILED — the stack may be half-restored. Resume with: make vault-restore"
    note "pre-restore backups: $VAULT_BACKUPS"
    exit 1
  fi
  rm -f "$MARKER"
  note "vault restore complete."
}

# restore_from_git: no vault seeds on disk (no vault key / LOCAL mode) — the committed snapshot.
restore_from_git() {
  note "all running primary engines empty → restoring the full snapshot (all engines)…"
  note "source: git-committed snapshot apps/grobase/data-snapshots, taken $(snapshot_vintage) — no vault seeds in ./secrets"
  CONFIRM=1 "$RESTORE"
  # The pg --clean restore swaps the schema under the postgres-connected services, leaving
  # them stale/unhealthy — bounce them (and the storage/realtime CDC) so they reconnect.
  docker restart mini-baas-minio mini-baas-realtime mini-baas-postgrest mini-baas-supavisor >/dev/null 2>&1 || true
  note "restore complete."
}

EMPTY=1
REASON=""

# gate <engine> <count|?>: a data-bearing or unreadable engine means "not fresh".
gate() {
  [ "$EMPTY" = 1 ] || return 0
  case "$2" in
  0) : ;;
  '?')
    EMPTY=0
    REASON="$1 unreadable"
    ;;
  *) if numeric "$2" && [ "$2" -gt 0 ]; then
    EMPTY=0
    REASON="$1 has data ($2)"
  fi ;;
  esac
}

# pg_probe: postgres is the one engine every edition runs and the one holding the users and
# pages, so "not running" is NOT "empty" — it is unknown, and unknown skips the restore.
# Treating it as empty let a stack whose postgres happened to be down (with mysql/mongo
# absent or empty) replay the snapshot over its data the moment postgres came back.
pg_probe() {
  running mini-baas-postgres || {
    EMPTY=0
    REASON="postgres is not running — cannot confirm the stack is empty"
    return 0
  }
  docker exec mini-baas-postgres pg_isready -U postgres -q 2>/dev/null || {
    gate postgres '?'
    return 0
  }
  # Two steps: a query that hard-references osionos_pages PARSE-fails when the table is
  # absent (fresh machine) — even inside a CASE — so check existence first, count only if present.
  ex=$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
    "SELECT (to_regclass('public.osionos_pages') IS NOT NULL)" 2>/dev/null | tr -d '[:space:]')
  case "$ex" in
  f) c=0 ;;
  t)
    c=$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc "SELECT count(*) FROM osionos_pages" 2>/dev/null | tr -d '[:space:]')
    numeric "$c" || c='?'
    ;;
  *) c='?' ;;
  esac
  gate postgres "$c"
}

mysql_probe() {
  running mini-baas-mysql || return 0
  pw=$(docker exec mini-baas-mysql printenv MYSQL_ROOT_PASSWORD 2>/dev/null)
  [ -n "$pw" ] || {
    gate mysql '?'
    return 0
  }
  c=$(docker exec mini-baas-mysql mysql -uroot -p"$pw" -N -e \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='ops'" 2>/dev/null | tr -d '[:space:]')
  numeric "$c" || c='?'
  gate mysql "$c"
}

mongo_probe() {
  running mini-baas-mongo || return 0
  mu=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME 2>/dev/null)
  mp=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD 2>/dev/null)
  { [ -n "$mu" ] && [ -n "$mp" ]; } || {
    gate mongo '?'
    return 0
  }
  c=$(docker exec mini-baas-mongo mongosh --quiet -u "$mu" -p "$mp" --authenticationDatabase admin \
    --eval 'db.getSiblingDB("activity").events.countDocuments()' 2>/dev/null | tr -d '[:space:]')
  numeric "$c" || c='?'
  gate mongo "$c"
}

refuse_unfinished_restore

# Engines are still booting after a detached `up` — wait for health before probing/restoring.
for e in mini-baas-postgres mini-baas-mysql mini-baas-mongo mini-baas-mssql mini-baas-minio; do
  wait_healthy "$e"
done

pg_probe
mysql_probe
mongo_probe

if [ "$EMPTY" != 1 ]; then
  note "data present ($REASON) — skipping restore (no wipe)."
elif vault_seeds_present; then
  restore_from_vault
else
  restore_from_git
fi
