#!/bin/sh
# ai-triggers-rollback.sql.sh — release R-C3: prints the SQL that drops ONLY the
# triggers the AI migrations put on NON-ai tables (the core tables the live app
# writes: osionos_pages, osionos_workspace_members, osionos_feed_*, ...), so a
# broken trigger can be removed without restoring the whole dump.
#
# Caveat: regex parse of CREATE [CONSTRAINT|OR REPLACE] TRIGGER ... ON <table>;
# a trigger created by dynamic SQL (EXECUTE inside a DO block) is missed. Those
# DO blocks are found by grep and printed as comments for the operator to read.
# Triggers on ai_* tables are left alone: they vanish with the ai_* tables.
# Functions are not dropped (a function without trigger is inert; dropping them
# can break the ai_* side). Usage: sh scripts/rollback/ai-triggers-rollback.sql.sh
set -eu

cd "$(dirname "$0")/../.."
files=$(ls models/osionos-ai-*.sql models/osionos-user-events-migration.sql \
	models/osionos-ugc-moderation-migration.sql models/osionos-membership-cutoff*.sql \
	models/osionos-page-version-migration.sql models/osionos-rec-*.sql 2>/dev/null)

echo "-- Rollback of the AI migrations' triggers on non-ai tables (generated, do not edit)."
echo "-- Source files:"
for f in $files; do echo "--   $f"; done
echo "BEGIN;"
echo "SET lock_timeout = '5s';"
# shellcheck disable=SC2086
awk '
	/^[ \t]*--/ { next }
	stmt == "" && /^[ \t]*CREATE[ \t]+(CONSTRAINT[ \t]+|OR[ \t]+REPLACE[ \t]+)?TRIGGER[ \t]/ { stmt = $0; if ($0 ~ /;/) flush(); next }
	stmt != "" { stmt = stmt " " $0; if ($0 ~ /;/) flush() }
	function flush(   name, rest, tbl, bare) {
		name = stmt; sub(/.*TRIGGER[ \t]+/, "", name); sub(/[ \t].*/, "", name)
		rest = stmt; sub(/^.*[ \t]ON[ \t]+/, "", rest); sub(/[ \t(;].*/, "", rest); tbl = rest
		bare = tbl; sub(/^.*\./, "", bare)
		if (bare !~ /^ai_/) { key = name " " tbl; if (!(key in seen)) { seen[key] = 1; printf "DROP TRIGGER IF EXISTS %s ON %s;\n", name, tbl } }
		stmt = ""
	}
' $files
echo "COMMIT;"
echo "-- DO blocks that run dynamic SQL (a trigger created there is NOT covered above):"
# shellcheck disable=SC2086
grep -n -i "EXECUTE[[:space:]]*\(format\)\?[[:space:]]*(\?'[^']*TRIGGER" $files | sed 's/^/--   /' || true
echo "--   (none above = no dynamic CREATE TRIGGER found)"
