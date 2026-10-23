#!/bin/sh
# ============================================================================
# apply-models.sh — a small, safe migration runner for the root-app models/*.sql.
#
# WHY THIS EXISTS
#   models/*.sql had no runner at all. A committed migration
#   (osionos-code-surface-migration.sql) therefore silently never applied to the
#   live DB, so every osionos IDE dev-file insert (surface='code') failed with
#   `23514 check_violation` — which read to the user as "can't create a page".
#   This runner makes "forgot to apply a migration" a caught, visible condition.
#
# HOW IT STAYS SAFE
#   The osionos migrations are NOT replay-safe as a set: several redefine the
#   whole `osionos_pages_surface_check` constraint (DROP+ADD), so re-running them
#   out of order would clobber it (e.g. `folder` after `code` drops 'code'), and
#   a few carry non-idempotent INSERTs. So we NEVER blindly replay. Instead a
#   checksum ledger (public.osionos_model_migrations) records each file that is
#   applied; a file runs only when it is new or its content changed.
#
#   Adoption: on an already-migrated DB (ledger empty but the schema is present),
#   `apply` ADOPTS — it records every current file as applied WITHOUT running it.
#   That's the correct, safe way to bring an existing DB under the ledger.
#
# SUBCOMMANDS
#   apply     (default) adopt on first run, else apply pending/changed migrations
#   baseline  record all current files as applied, never running SQL
#   check     exit 1 if any migration is pending (read-only verify gate)
#   status    print per-file up-to-date / pending
#   order     print the files in the order apply runs them (no database)
#
# ENV: PG_CONTAINER=mini-baas-postgres PG_DB=postgres PG_USER=postgres MODELS_DIR=models
# ============================================================================
set -eu

PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
PG_DB="${PG_DB:-postgres}"
PG_USER="${PG_USER:-postgres}"
MODELS_DIR="${MODELS_DIR:-models}"
CMD="${1:-apply}"

ERRFILE=""
cleanup() { if [ -n "$ERRFILE" ]; then rm -f "$ERRFILE"; fi; }
trap cleanup EXIT

psql_do() {
	docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"
}

require_pg() {
	if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$PG_CONTAINER"; then
		echo "[apply-models] $PG_CONTAINER not running — skipping (bring the backend up first)." >&2
		exit 0
	fi
}

# The ledger sits in public, where grobase's default privileges grant anon and
# authenticated everything: without RLS the public anon key could rewrite it through
# PostgREST and mark a migration applied (2026-10-11, measured on the VM). RLS with no
# policy shuts both roles out; this runner is the postgres superuser and bypasses it.
ledger_ensure() {
	psql_do -q >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS public.osionos_model_migrations (
  filename   text PRIMARY KEY,
  sha256     text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.osionos_model_migrations ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.osionos_model_migrations FROM %I', r);
    END IF;
  END LOOP;
END $$;
SQL
}

ledger_count() { psql_do -tAqc "SELECT count(*) FROM public.osionos_model_migrations;" 2>/dev/null || echo 0; }
schema_present() { psql_do -tAqc "SELECT (to_regclass('public.osionos_pages') IS NOT NULL);" 2>/dev/null || echo f; }
recorded_sum() { psql_do -tAqc "SELECT sha256 FROM public.osionos_model_migrations WHERE filename = '$1';" 2>/dev/null || true; }

record() {
	psql_do -q >/dev/null <<SQL
INSERT INTO public.osionos_model_migrations (filename, sha256) VALUES ('$1', '$2')
ON CONFLICT (filename) DO UPDATE SET sha256 = EXCLUDED.sha256, applied_at = now();
SQL
}

file_sum() { sha256sum "$1" | cut -d' ' -f1; }

# The glob follows LC_COLLATE: under en_US.UTF-8 `users-pii-grants-migration.sql` sorts before
# `user.sql`. The users grants file must override every grant before it, so it goes last by
# name, not by collation (ADR 0014, ML-7). Paths are word-split: MODELS_DIR has no spaces.
GRANTS_LAST=users-pii-grants-migration.sql
ordered_models() {
	for f in "$MODELS_DIR"/*.sql; do
		[ -f "$f" ] || continue
		[ "$(basename "$f")" = "$GRANTS_LAST" ] || printf '%s\n' "$f"
	done
	if [ -f "$MODELS_DIR/$GRANTS_LAST" ]; then printf '%s\n' "$MODELS_DIR/$GRANTS_LAST"; fi
}

# Record every current file as applied without running any SQL.
adopt_all() {
	for f in "$MODELS_DIR"/*.sql; do
		[ -f "$f" ] || continue
		record "$(basename "$f")" "$(file_sum "$f")"
	done
}

main() {
	if [ "$CMD" = "order" ]; then
		ordered_models
		return 0
	fi
	require_pg
	ledger_ensure

	# Adoption: existing schema + empty ledger → baseline, never replay.
	if [ "$CMD" = "apply" ] && [ "$(ledger_count)" = "0" ] && [ "$(schema_present)" = "t" ]; then
		adopt_all
		echo "[apply-models] adopted the existing schema into the ledger (no SQL run); new migrations will apply from here."
		return 0
	fi

	applied=0; skipped=0; failed=0; pending=0
	ERRFILE=$(mktemp)
	for f in $(ordered_models); do
		[ -f "$f" ] || continue
		name=$(basename "$f")
		sum=$(file_sum "$f")
		if [ "$(recorded_sum "$name")" = "$sum" ]; then
			skipped=$((skipped + 1))
			[ "$CMD" = "status" ] && printf '  up-to-date  %s\n' "$name"
			continue
		fi
		case "$CMD" in
			check|status)
				printf '  PENDING     %s\n' "$name"
				pending=$((pending + 1))
				;;
			baseline)
				record "$name" "$sum"
				printf '  baselined   %s\n' "$name"
				applied=$((applied + 1))
				;;
			apply)
				printf '  applying    %s ... ' "$name"
				if psql_do -q <"$f" >/dev/null 2>"$ERRFILE"; then
					record "$name" "$sum"
					echo "OK"
					applied=$((applied + 1))
				else
					echo "FAIL"
					sed 's/^/      /' "$ERRFILE" | tail -4 >&2
					failed=$((failed + 1))
				fi
				;;
			*)
				echo "usage: apply-models.sh [apply|baseline|check|status|order]" >&2
				exit 2
				;;
		esac
	done

	case "$CMD" in
		check)
			if [ "$pending" -gt 0 ]; then
				echo "[apply-models] $pending pending migration(s) — run 'make apply-models'." >&2
				exit 1
			fi
			echo "[apply-models] all migrations applied."
			;;
		status) echo "[apply-models] $skipped up-to-date, $pending pending." ;;
		baseline) echo "[apply-models] baselined $applied file(s) (no SQL run)." ;;
		apply)
			echo "[apply-models] $applied applied, $skipped up-to-date, $failed failed."
			[ "$failed" -eq 0 ]
			;;
	esac
}

main
