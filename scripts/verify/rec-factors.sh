#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    rec-factors.sh                                                            #
#                                                                              #
#    Prove the recommender's model in Postgres: the registry with ONE         #
#    champion, the zero-padded factors, the HNSW search, the guarded          #
#    promotion, the prune, the erasure and the rollback.                        #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-rec-factors-migration.sql)
#   1  a 16-factor model stored as vector(64) scores the SAME inner product as
#      the 16-dim dot product computed OUTSIDE the database (to 1e-5): the
#      padding is zeros, so the padding changes nothing
#   2  the HNSW index is the plan (the EXPLAIN names it) and its top-20 is the
#      exact top-20 of the 2,000 rows (the recall is printed)
#   3  the promotion: one champion at a time (a second one is refused with
#      23505), a worse candidate is refused (P0001), p_force promotes it and
#      retires the old champion, a synthetic candidate never replaces a real
#      one, and the first candidate is promoted when there is no champion
#   4  the prune keeps the 2 newest retired models, deletes the candidates
#      older than 7 days, and takes their factor rows with them (cascade)
#   5  the erasure: ai_rec_erase_user deletes the user's vectors in EVERY
#      model and the rows where the user is an item, leaves the other user's
#      rows, and ai_erase_user (the events file) clears them too — on a
#      database that never had the factors migration as well
#   6  anon and authenticated cannot read a table and cannot call a function
#   7  the rollback (twice) leaves none of the new objects behind and
#      ai_erase_user still works
#
# THE FIXTURE
#   The roles of scripts/verify/models-grants/roles.sql, then the PRE-1e407614
#   default privileges (anon and authenticated get everything on every table
#   created from here on) so that the migration's own REVOKE is what closes
#   them — otherwise check 6 would pass for the wrong reason. Then the
#   prerequisite models, then the events migration (the erasure of check 5 is
#   ai_erase_user), then the migration itself TWICE.
#
#   A SECOND DATABASE (the same container) holds the events migration alone,
#   without the factors migration: that is what proves the events file stays
#   valid on a database that never had this migration.
#
# ISOLATION
#   Throwaway containers only: rec-fac-pg, --network none, no port, no
#   volume. The live mini-baas / osionos containers are never touched. The
#   container is removed on every exit path.
#
# Usage:  sh scripts/verify/rec-factors.sh [--keep]
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317
# The check_* functions are called through the loop in main(), so shellcheck
# cannot see that they are reached (the house's own check files disable it the
# same way).
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
MIGRATION="osionos-rec-factors-migration.sql"
ROLLBACK="${MODELS}/rollback/osionos-rec-factors-rollback.sql"
CTN="rec-fac-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
EVENTS_DB="rec_events_only"
ALONE_DB="rec_standalone"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rec-factors.XXXXXX")"
passed=0
failed=0
DETAIL=""
DESCR=""
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# The test data. Three users, so no check can see another's rows: U1 carries
# the rows of the padding and of the prune, U2 is the OTHER user of the
# erasure, and U3 is the user the erasure removes (no other check writes a
# row for U3, so the count of the erasure is exactly known).
U1=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
U2=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
U3=cccccccc-cccc-cccc-cccc-cccccccccccc

# The 16 REAL coordinates of the two vectors of check 1. The rest (48) are
# the padding, and the check proves the padding is zeros.
U16="0.5 -0.25 0.125 1.5 -2 0.75 3.25 -0.5 0 1.125 -1.75 2.5 0.375 -0.625 4 0.0625"
I16="1 2 -0.5 0.25 -3 0.125 0.5 2.75 -1 0.375 1.25 -0.25 0.0625 3.5 -0.75 1.5"

# The query vector of the HNSW search of check 2: 64 coordinates.
Q64="$(awk 'BEGIN { s = "["; for (i = 1; i <= 64; i++) s = s (i > 1 ? "," : "") (i / 10); printf "%s]", s }')"

note() { printf '[rec-factors] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS: %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s %s\n' "$1" "$2"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: container ${CTN} left up"; return 0; }
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }

# psql_db <db> — the same, on another database of the same container.
psql_db() {
	docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt
}

# run_sql <sql> — psql runs it. stdout in ${WORK}/sql.out, stderr in
# ${WORK}/sql.err. The exit code is psql's.
run_sql() {
	printf '%s\n' "$1" | psql_q >"${WORK}/sql.out" 2>"${WORK}/sql.err"
}

# run_file <path> — the same, from a file (for the SQL that needs a quoted
# dollar-quote).
run_file() {
	docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt \
		<"$1" >"${WORK}/sql.out" 2>"${WORK}/sql.err"
}

# q <sql> — the rows, one per line. A failing query prints nothing and is not
# an error here: the check that asked for it decides.
q() { printf '%s\n' "$1" | psql_q 2>/dev/null || true; }

# state_of <sql> — the SQLSTATE the statement was refused with; empty when the
# statement was accepted.
state_of() {
	err="${WORK}/state.err"
	if printf '%s\n' '\set VERBOSITY sqlstate' "$1" |
		psql_q >/dev/null 2>"${err}"; then
		printf ''
		return 0
	fi
	sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | head -1
}

# state_of_db <db> <sql> — the same, on another database.
state_of_db() {
	err="${WORK}/state.err"
	if printf '%s\n' '\set VERBOSITY sqlstate' "$2" |
		psql_db "$1" >/dev/null 2>"${err}"; then
		printf ''
		return 0
	fi
	sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | head -1
}

apply_file() {
	if docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		<"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

# apply_file_db <db> <path> — the same, on another database.
apply_file_db() {
	if docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q \
		<"$2" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$2") on $1"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

ensure_image() {
	if docker image inspect "${PG_IMAGE}" >/dev/null 2>&1; then
		return 0
	fi
	note "pulling ${PG_IMAGE}"
	if docker pull "${PG_IMAGE}" >/dev/null 2>&1; then
		return 0
	fi
	printf 'FAIL: image %s\n' "${PG_IMAGE}"
	exit 1
}

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	ensure_image
	docker run -d --name "${CTN}" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
		"${PG_IMAGE}" >/dev/null || {
		note "the container did not start"
		exit 1
	}
	i=0
	while [ "${i}" -lt 60 ]; do
		docker exec "${CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	note "postgres never became ready"
	exit 1
}

# The prerequisite models, in the order they need each other (the runner's
# ORDERED_FIRST first, then the alphabetical pass).
PREREQS="osionos-bridge-migration.sql osionos-chat-migration.sql
osionos-social-migration.sql osionos-engagement-migration.sql
osionos-comments-migration.sql osionos-favorites-migration.sql
osionos-feed-engagement-migration.sql"

apply_prereqs() {
	for base in ${PREREQS}; do
		apply_file "${MODELS}/${base}" || return 1
	done
	return 0
}

# The events-only database: the events migration and NOTHING of the factors
# migration. It is what proves the events file stands alone.
apply_events_only_db() {
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "DROP DATABASE IF EXISTS ${EVENTS_DB};" >"${WORK}/apply.log" 2>&1 || return 1
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "CREATE DATABASE ${EVENTS_DB};" >>"${WORK}/apply.log" 2>&1 || return 1
	# The roles are cluster-wide and are already there; the schema and its
	# grants are per-database.
	printf 'CREATE SCHEMA IF NOT EXISTS auth;\nGRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;\nGRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;\nGRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;\nALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;\nALTER ROLE postgres IN DATABASE %s SET search_path = auth, public;\n' \
		"${EVENTS_DB}" | psql_db "${EVENTS_DB}" >"${WORK}/apply.log" 2>&1 || return 1
	for base in ${PREREQS}; do
		apply_file_db "${EVENTS_DB}" "${MODELS}/${base}" || return 1
	done
	apply_file_db "${EVENTS_DB}" "${MODELS}/osionos-user-events-migration.sql" || return 1
	return 0
}

# pad <16 numbers> — the 64-dimensional literal: the 16 real coordinates and
# 48 zeros. The padding is what makes one column hold every model.
pad() {
	awk -v vals="$1" 'BEGIN {
		n = split(vals, a, " ")
		s = a[1]
		for (i = 2; i <= n; i++) s = s "," a[i]
		for (i = n + 1; i <= 64; i++) s = s ",0"
		printf "[%s]", s
	}'
}

# dot16 <u> <i> — the 16-dim dot product, computed OUTSIDE the database, so
# the check does not compare the database with itself.
dot16() {
	awk -v u="$1" -v i="$2" 'BEGIN {
		nu = split(u, ua, " ")
		ni = split(i, ia, " ")
		s = 0
		for (k = 1; k <= nu && k <= ni; k++) s += ua[k] * ia[k]
		printf "%.10f", s
	}'
}

# close <a> <b> — 0 when the two numbers are within 1e-5, 1 otherwise.
close() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		d = a - b
		if (d < 0) d = -d
		exit (d <= 1e-5) ? 0 : 1
	}'
}

apply_migration() { apply_file "${MODELS}/${MIGRATION}"; }

apply_fixture() {
	apply_file "${FIX}/roles.sql" || return 1
	# The live stack's search_path: grobase's 001_initial_schema.sql sets it on
	# the postgres role, and it starts with auth. A relation created without a
	# schema lands in the FIRST schema of the search_path, so this fixture
	# would have put a table in the auth schema — the migration has to spell
	# the schema out.
	printf 'ALTER ROLE postgres IN DATABASE postgres SET search_path = auth, public;\n' |
		docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/apply.log" 2>&1 || {
		note "the search_path could not be set"
		return 1
	}
	# The pre-1e407614 default privileges: anon and authenticated get
	# everything on every table created from here on. The migration's own
	# REVOKE has to close them, or check 6 would pass for the wrong reason.
	printf 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;\n' |
		docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/apply.log" 2>&1 || {
		note "the legacy default privileges failed"
		return 1
	}
	apply_prereqs || {
		note "the fixture could not apply the prerequisite models"
		return 1
	}
	# The events migration: check 5 erases through ai_erase_user, and check 7
	# proves it still runs after the rollback.
	apply_file "${MODELS}/osionos-user-events-migration.sql" || {
		note "the fixture could not apply the events migration"
		return 1
	}
	# The migration, twice.
	apply_migration || return 1
	apply_migration || return 1
	# The events-only database: the events migration alone.
	apply_events_only_db || {
		note "the fixture could not build the events-only database"
		return 1
	}
	return 0
}

# The runner's alphabetical pass, read from the runner's own source: the files
# of models/*.sql that are in neither ORDERED_FIRST, nor ORDERED_LAST, nor
# skipped(). A file in ORDERED_FIRST is applied before the whole pass.
runner_alphabetical() {
	first="$(sed -n 's/^ORDERED_FIRST="\(.*\)"$/\1/p' "${RUNNER}")"
	last="$(sed -n 's/^ORDERED_LAST="\(.*\)"$/\1/p' "${RUNNER}")"
	skipped="$(sed -n '/^skipped() {/,/^}/p' "${RUNNER}" | grep -o '[a-z0-9-]*\.sql' | tr '\n' ' ')"
	for f in "${MODELS}"/*.sql; do
		base="$(basename "$f")"
		case " ${first} " in *" ${base} "*) continue ;; esac
		case " ${last} " in *" ${base} "*) continue ;; esac
		case " ${skipped} " in *" ${base} "*) continue ;; esac
		printf '%s\n' "${base}"
	done
}

# --- the checks ------------------------------------------------------------

# 0 — the runner applies the migration, and the migration stands ALONE.
#
#     The header says the file may sort before the events file because it
#     references NOTHING in it. That claim is proved here, not asserted: on a
#     database with neither the events migration nor the prerequisite models,
#     the migration applies TWICE and leaves its objects behind.
check_0() {
	order="$(runner_alphabetical)"
	mine="$(printf '%s\n' "${order}" | grep -n "^${MIGRATION}\$" | cut -d: -f1 || true)"
	[ -n "${mine}" ] || {
		DETAIL="${MIGRATION} is not in the runner's alphabetical pass"
		return 1
	}
	# A database of its own: the roles are cluster-wide and are already
	# there; the schema and its grants are per-database.
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "DROP DATABASE IF EXISTS ${ALONE_DB};" >"${WORK}/apply.log" 2>&1 || return 1
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "CREATE DATABASE ${ALONE_DB};" >>"${WORK}/apply.log" 2>&1 || return 1
	printf 'CREATE SCHEMA IF NOT EXISTS auth;\nGRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;\nGRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;\nALTER ROLE postgres IN DATABASE %s SET search_path = auth, public;\n' \
		"${ALONE_DB}" | psql_db "${ALONE_DB}" >"${WORK}/apply.log" 2>&1 || {
		DETAIL="the standalone database could not be prepared"
		return 1
	}
	for pass in 1 2; do
		if ! apply_file_db "${ALONE_DB}" "${MODELS}/${MIGRATION}"; then
			DETAIL="the migration did not apply alone (pass ${pass})"
			return 1
		fi
	done
	n="$(printf '%s\n' "SELECT count(*) FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE ns.nspname = 'public' AND c.relname IN ('ai_rec_models','ai_rec_item_factors','ai_rec_user_factors');" |
		psql_db "${ALONE_DB}" 2>/dev/null || true)"
	[ "${n}" = "3" ] || {
		DETAIL="${n:-no} table(s) on the standalone database, expected 3"
		return 1
	}
	# The events file is not there, so the erasure it calls is not there
	# either: the new file does not need it.
	present="$(printf '%s\n' "SELECT to_regprocedure('public.ai_erase_user(uuid)') IS NOT NULL;" |
		psql_db "${ALONE_DB}" 2>/dev/null || true)"
	[ "${present}" = "f" ] || {
		DETAIL="the standalone database holds the events function"
		return 1
	}
	DESCR="the runner applies the migration, and it applies alone on a database without the events migration"
	return 0
}

# 1 — the padding: a 16-factor model stored as vector(64) scores the same as
#     the 16-dim dot product.
check_1() {
	uv="$(pad "${U16}")"
	iv="$(pad "${I16}")"
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha)
VALUES ('ials', 16, 0.1, 0.01, 10, 1000, now(), '{\"ndcg10\": 0.11, \"recall20\": 0.30}'::jsonb, true, 'a1a1a1a');" || {
		note "the 16-factor model failed"
		return 1
	}
	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'a1a1a1a';")"
	[ -n "${mid}" ] || {
		DETAIL="the 16-factor model is not in the registry"
		return 1
	}
	run_sql "INSERT INTO public.ai_rec_user_factors (model_id, user_id, factors) VALUES (${mid}, '${U1}', '${uv}'::vector);
INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors) VALUES (${mid}, 'page', '33333333-3333-3333-3333-333333333333', '${iv}'::vector);" || {
		note "the padded vectors failed"
		return 1
	}
	# The stored vectors are 64-dimensional, whatever the model says.
	dims="$(q "SELECT array_length(string_to_array(trim(both '[]' from factors::text), ','), 1) FROM public.ai_rec_user_factors WHERE model_id = ${mid};")"
	[ "${dims}" = "64" ] || {
		DETAIL="the stored vector has ${dims:-no} dimension(s), expected 64"
		return 1
	}
	# The inner product the DATABASE computes over the padded pair. In
	# pgvector 0.8.0 '<#>' is the NEGATIVE inner product and '<+>' is the L1
	# distance, so the inner product is -(a <#> b).
	sql="$(q "SELECT -(u.factors <#> i.factors) FROM public.ai_rec_user_factors u, public.ai_rec_item_factors i WHERE u.model_id = ${mid} AND i.model_id = ${mid} AND i.item_kind = 'page';")"
	expected="$(dot16 "${U16}" "${I16}")"
	if [ -z "${sql}" ]; then
		DETAIL="the database computed no inner product"
		return 1
	fi
	if ! close "${sql}" "${expected}"; then
		DETAIL="the padded inner product is ${sql}, the 16-dim dot product is ${expected}"
		return 1
	fi
	DESCR="a 16-factor model padded to 64 scores the same inner product (${sql})"
	return 0
}

# 2 — the HNSW index is the plan, and it finds the exact top-20.
check_2() {
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha)
VALUES ('ials', 64, 0.1, 0.01, 10, 2000, now(), '{\"ndcg10\": 0.12}'::jsonb, true, 'b2b2b2b');" || {
		note "the 64-factor model failed"
		return 1
	}
	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'b2b2b2b';")"
	[ -n "${mid}" ] || {
		DETAIL="the 64-factor model is not in the registry"
		return 1
	}
	# 2,000 item rows of that one model, deterministic (no random()).
	run_sql "INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors)
SELECT ${mid}, 'page', ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
       ('[' || (SELECT string_agg((((i * 31 + d * 17) % 2000)::numeric / 1000 - 1)::text, ',' ORDER BY d)
                   FROM generate_series(1, 64) d) || ']')::vector
  FROM generate_series(1, 2000) i;" || {
		note "the 2,000 item rows failed"
		return 1
	}
	run_sql "ANALYZE public.ai_rec_item_factors;" || {
		note "the analyze failed"
		return 1
	}
	# The query the service runs: the champion's items, nearest first.
	query="SELECT item_id FROM public.ai_rec_item_factors WHERE model_id = ${mid} ORDER BY factors <#> '${Q64}'::vector LIMIT 20;"
	run_sql "SET enable_seqscan = off; EXPLAIN ${query}" || {
		note "the explain failed"
		return 1
	}
	plan="$(cat "${WORK}/sql.out")"
	case "${plan}" in
	*ai_rec_item_factors_hnsw_idx*) ;;
	*)
		DETAIL="the plan does not name the HNSW index: $(printf '%s' "${plan}" | tr '\n' ' ')"
		return 1
		;;
	esac
	case "${plan}" in
	*"Index Scan"*) ;;
	*)
		DETAIL="the plan is not an index scan: $(printf '%s' "${plan}" | tr '\n' ' ')"
		return 1
		;;
	esac
	# The HNSW top-20, and the exact top-20: the index scan is off for the
	# exact one, so it is a scan and a sort.
	q "${query}" | sort >"${WORK}/hnsw.txt"
	q "SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT item_id FROM public.ai_rec_item_factors WHERE model_id = ${mid} ORDER BY -(factors <#> '${Q64}'::vector) DESC LIMIT 20;" |
		sort >"${WORK}/exact.txt"
	hits="$(comm -12 "${WORK}/hnsw.txt" "${WORK}/exact.txt" | wc -l | tr -d ' ')"
	[ "${hits}" -ge 19 ] || {
		DETAIL="the HNSW top-20 and the exact top-20 share ${hits} row(s), expected 20"
		return 1
	}
	DESCR="the plan uses the HNSW index and its top-20 matches the exact one (recall ${hits}/20)"
	return 0
}

# 3 — the promotion: one champion, and never a worse one.
check_3() {
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha) VALUES
  ('ials', 32, 0.1, 0.01, 10, 1000, now(), '{\"ndcg10\": 0.12}'::jsonb, false, 'c3c3c3c'),
  ('ials', 32, 0.1, 0.01, 10, 1000, now(), '{\"ndcg10\": 0.10}'::jsonb, false, 'd3d3d3d'),
  ('ials', 32, 0.1, 0.01, 10, 1000, now(), '{\"ndcg10\": 0.99}'::jsonb, true,  'e3e3e3e');" || {
		note "the candidate models failed"
		return 1
	}
	champ="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'c3c3c3c';")"
	worse="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'd3d3d3d';")"
	synth="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'e3e3e3e';")"
	# No champion yet: the first candidate is promoted.
	out="$(q "SELECT public.ai_rec_promote(${champ});")"
	[ "${out}" = "promoted" ] || {
		DETAIL="the first promotion returned ${out:-nothing}, expected promoted"
		return 1
	}
	st="$(q "SELECT status FROM public.ai_rec_models WHERE id = ${champ};")"
	[ "${st}" = "champion" ] || {
		DETAIL="the first promoted model is ${st:-nothing}, expected champion"
		return 1
	}
	# A worse candidate is refused, and the champion does not move.
	st="$(state_of "SELECT public.ai_rec_promote(${worse});")"
	[ "${st}" = "P0001" ] || {
		DETAIL="the promotion of a worse candidate was refused with ${st:-no error}, expected P0001"
		return 1
	}
	now_champ="$(q "SELECT id FROM public.ai_rec_models WHERE status = 'champion';")"
	[ "${now_champ}" = "${champ}" ] || {
		DETAIL="the refused promotion moved the champion to ${now_champ:-nothing}"
		return 1
	}
	# p_force promotes it anyway, and the old champion is retired.
	out="$(q "SELECT public.ai_rec_promote(${worse}, true);")"
	[ "${out}" = "promoted" ] || {
		DETAIL="the forced promotion returned ${out:-nothing}, expected promoted"
		return 1
	}
	st="$(q "SELECT status FROM public.ai_rec_models WHERE id = ${worse};")"
	[ "${st}" = "champion" ] || {
		DETAIL="the forced promotion left the model ${st:-nothing}, expected champion"
		return 1
	}
	st="$(q "SELECT status FROM public.ai_rec_models WHERE id = ${champ};")"
	[ "${st}" = "retired" ] || {
		DETAIL="the old champion is ${st:-nothing}, expected retired"
		return 1
	}
	# A synthetic candidate never replaces a real champion.
	st="$(state_of "SELECT public.ai_rec_promote(${synth});")"
	[ "${st}" = "P0001" ] || {
		DETAIL="the promotion of a synthetic candidate was refused with ${st:-no error}, expected P0001"
		return 1
	}
	st="$(q "SELECT status FROM public.ai_rec_models WHERE id = ${synth};")"
	[ "${st}" = "candidate" ] || {
		DETAIL="the refused synthetic model is ${st:-nothing}, expected candidate"
		return 1
	}
	# A model that is not a candidate is refused too.
	st="$(state_of "SELECT public.ai_rec_promote(${champ});")"
	[ "${st}" = "P0001" ] || {
		DETAIL="the promotion of a retired model was refused with ${st:-no error}, expected P0001"
		return 1
	}
	# One champion at a time: a second one is refused by the database itself.
	st="$(state_of "UPDATE public.ai_rec_models SET status = 'champion' WHERE id = ${synth};")"
	[ "${st}" = "23505" ] || {
		DETAIL="a second champion was refused with ${st:-no error}, expected 23505"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_models WHERE status = 'champion';")"
	[ "${n}" = "1" ] || {
		DETAIL="${n} champion(s), expected 1"
		return 1
	}
	DESCR="one champion: a worse candidate is refused, p_force retires the old one, a synthetic never replaces a real one"
	return 0
}

# 4 — the prune: the 2 newest retired models stay, their factors go by
#     cascade, and a candidate older than 7 days goes.
check_4() {
	# The two retired models of check 3 go first, so the counting below is
	# about the models this check creates.
	q "SELECT public.ai_rec_prune(0);" >/dev/null
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha, status, created_at) VALUES
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.10}'::jsonb, false, 'f4f4f41', 'retired', now() - interval '4 days'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.11}'::jsonb, false, 'f4f4f42', 'retired', now() - interval '3 days'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.12}'::jsonb, false, 'f4f4f43', 'retired', now() - interval '2 days'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.13}'::jsonb, false, 'f4f4f44', 'retired', now() - interval '1 day'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.14}'::jsonb, false, 'f4f4f45', 'candidate', now() - interval '10 days'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.15}'::jsonb, false, 'f4f4f46', 'candidate', now());" || {
		note "the models of the prune failed"
		return 1
	}
	# Three item rows and two user rows for each retired model.
	run_sql "INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors)
SELECT m.id, 'page', ('11111111-1111-1111-1111-' || lpad((m.id * 10 + i)::text, 12, '0'))::uuid,
       ('[' || (SELECT string_agg((0.1 * d)::text, ',' ORDER BY d) FROM generate_series(1, 64) d) || ']')::vector
  FROM public.ai_rec_models m CROSS JOIN generate_series(1, 3) i
 WHERE m.code_sha IN ('f4f4f41','f4f4f42','f4f4f43','f4f4f44');
INSERT INTO public.ai_rec_user_factors (model_id, user_id, factors)
SELECT m.id, '${U1}', ('[' || (SELECT string_agg((0.2 * d)::text, ',' ORDER BY d) FROM generate_series(1, 64) d) || ']')::vector
  FROM public.ai_rec_models m
 WHERE m.code_sha IN ('f4f4f41','f4f4f42','f4f4f43','f4f4f44');" || {
		note "the factor rows of the retired models failed"
		return 1
	}
	before_models="$(q "SELECT count(*) FROM public.ai_rec_models;")"
	before_items="$(q "SELECT count(*) FROM public.ai_rec_item_factors;")"
	before_users="$(q "SELECT count(*) FROM public.ai_rec_user_factors;")"
	cut="$(q "SELECT public.ai_rec_prune(2);")"
	[ "${cut}" = "3" ] || {
		DETAIL="the prune deleted ${cut:-nothing} model(s), expected 3 (2 retired, 1 old candidate)"
		return 1
	}
	after_models="$(q "SELECT count(*) FROM public.ai_rec_models;")"
	after_items="$(q "SELECT count(*) FROM public.ai_rec_item_factors;")"
	after_users="$(q "SELECT count(*) FROM public.ai_rec_user_factors;")"
	[ "$((before_models - after_models))" = "3" ] || {
		DETAIL="${before_models} models became ${after_models}, expected 3 fewer"
		return 1
	}
	# The two NEWEST retired models stay, the two oldest go.
	n="$(q "SELECT count(*) FROM public.ai_rec_models WHERE status = 'retired';")"
	[ "${n}" = "2" ] || {
		DETAIL="${n} retired model(s) left, expected 2"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_models WHERE code_sha IN ('f4f4f43','f4f4f44');")"
	[ "${n}" = "2" ] || {
		DETAIL="${n} of the 2 newest retired models left, expected 2"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_models WHERE code_sha IN ('f4f4f41','f4f4f42','f4f4f45');")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} of the 2 oldest retired models and the old candidate left, expected 0"
		return 1
	}
	# The champion is never pruned.
	n="$(q "SELECT count(*) FROM public.ai_rec_models WHERE status = 'champion';")"
	[ "${n}" = "1" ] || {
		DETAIL="${n} champion(s) after the prune, expected 1"
		return 1
	}
	# Their factor rows went with them: the 2 deleted models took 6 item rows
	# and 2 user rows with them.
	[ "$((before_items - after_items))" = "6" ] || {
		DETAIL="${before_items} item factors became ${after_items}, expected 6 fewer"
		return 1
	}
	[ "$((before_users - after_users))" = "2" ] || {
		DETAIL="${before_users} user factors became ${after_users}, expected 2 fewer"
		return 1
	}
	DESCR="the prune keeps the 2 newest retired models, deletes the old candidate and cascades their factors"
	return 0
}

# 5 — the erasure: the user's derived vectors go with the user.
check_5() {
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha) VALUES
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.20}'::jsonb, false, 'a5a5a5a'),
  ('ials', 32, 0.1, 0.01, 10, 100, now(), '{\"ndcg10\": 0.21}'::jsonb, false, 'b5b5b5b');" || {
		note "the two models of the erasure failed"
		return 1
	}
	m1="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'a5a5a5a';")"
	m2="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'b5b5b5b';")"
	# The user has a vector in BOTH models, and is an item in BOTH models.
	run_sql "INSERT INTO public.ai_rec_user_factors (model_id, user_id, factors) VALUES
  (${m1}, '${U3}', '$(pad "${U16}")'::vector),
  (${m2}, '${U3}', '$(pad "${U16}")'::vector),
  (${m1}, '${U2}', '$(pad "${I16}")'::vector),
  (${m2}, '${U2}', '$(pad "${I16}")'::vector);
INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors) VALUES
  (${m1}, 'user', '${U3}', '$(pad "${U16}")'::vector),
  (${m2}, 'user', '${U3}', '$(pad "${U16}")'::vector),
  (${m1}, 'user', '${U2}', '$(pad "${I16}")'::vector),
  (${m2}, 'user', '${U2}', '$(pad "${I16}")'::vector),
  (${m1}, 'page', '44444444-4444-4444-4444-444444444444', '$(pad "${I16}")'::vector);" || {
		note "the factor rows of the erasure failed"
		return 1
	}
	erased="$(q "SELECT public.ai_rec_erase_user('${U3}');")"
	[ "${erased}" = "4" ] || {
		DETAIL="the erase returned ${erased:-nothing}, expected 4 (2 user vectors, 2 user-as-item rows)"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_user_factors WHERE user_id = '${U3}';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} user vector(s) left for the erased user"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_item_factors WHERE item_kind = 'user' AND item_id = '${U3}';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} user-as-item row(s) left for the erased user"
		return 1
	}
	# The other user's rows stay, and so do the page rows.
	n="$(q "SELECT count(*) FROM public.ai_rec_user_factors WHERE user_id = '${U2}';")"
	[ "${n}" = "2" ] || {
		DETAIL="${n} user vector(s) left for the other user, expected 2"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_item_factors WHERE item_kind = 'user' AND item_id = '${U2}';")"
	[ "${n}" = "2" ] || {
		DETAIL="${n} user-as-item row(s) left for the other user, expected 2"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_item_factors WHERE item_kind = 'page';")"
	[ "${n}" -ge 1 ] || {
		DETAIL="the page rows were erased too"
		return 1
	}
	# The erasure is idempotent.
	erased="$(q "SELECT public.ai_rec_erase_user('${U3}');")"
	[ "${erased}" = "0" ] || {
		DETAIL="the second erase returned ${erased:-nothing}, expected 0"
		return 1
	}
	# ai_erase_user (the events file) erases the factors too.
	run_sql "INSERT INTO public.ai_rec_user_factors (model_id, user_id, factors) VALUES (${m1}, '${U3}', '$(pad "${U16}")'::vector);
INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors) VALUES (${m1}, 'user', '${U3}', '$(pad "${U16}")'::vector);" || {
		note "the factor rows of the second round failed"
		return 1
	}
	run_sql "SELECT public.ai_erase_user('${U3}');" || {
		note "ai_erase_user failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_user_factors WHERE user_id = '${U3}';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} user vector(s) left after ai_erase_user"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_rec_item_factors WHERE item_kind = 'user' AND item_id = '${U3}';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} user-as-item row(s) left after ai_erase_user"
		return 1
	}
	# The events file stands alone: on a database that never had this
	# migration, ai_erase_user still runs.
	st="$(state_of_db "${EVENTS_DB}" "SELECT public.ai_erase_user('${U2}');")"
	[ -z "${st}" ] || {
		DETAIL="ai_erase_user was refused on the events-only database with ${st}"
		return 1
	}
	present="$(printf '%s\n' "SELECT to_regprocedure('public.ai_rec_erase_user(uuid)') IS NOT NULL;" |
		psql_db "${EVENTS_DB}" 2>/dev/null || true)"
	[ "${present}" = "f" ] || {
		DETAIL="the events-only database holds the factors function (${present:-nothing})"
		return 1
	}
	DESCR="the erasure takes the user's vectors in every model and the rows where the user is an item"
	return 0
}

# 6 — the grants: service_role only.
check_6() {
	for role in anon authenticated; do
		for t in ai_rec_models ai_rec_item_factors ai_rec_user_factors; do
			if run_sql "SET ROLE ${role}; SELECT count(*) FROM public.${t};"; then
				DETAIL="${role} could read ${t}"
				return 1
			fi
			grep -q 'permission denied' "${WORK}/sql.err" || {
				DETAIL="${role} on ${t}: $(head -1 "${WORK}/sql.err")"
				return 1
			}
		done
		for call in "public.ai_rec_promote(1, false)" "public.ai_rec_prune(2)" \
			"public.ai_rec_erase_user('${U3}')"; do
			if run_sql "SET ROLE ${role}; SELECT ${call};"; then
				DETAIL="${role} could call ${call}"
				return 1
			fi
			grep -q 'permission denied' "${WORK}/sql.err" || {
				DETAIL="${role} on ${call}: $(head -1 "${WORK}/sql.err")"
				return 1
			}
		done
	done
	# The positive control: service_role reads the tables and calls the
	# functions (the erase of a user with no rows changes nothing).
	run_sql "SET ROLE service_role; SELECT count(*) FROM public.ai_rec_models; SELECT public.ai_rec_erase_user('${U3}');" || {
		DETAIL="service_role could not use the registry: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	DESCR="anon and authenticated cannot read a table nor call a function; service_role can"
	return 0
}

# 7 — the rollback: none of the new objects is left, and the events file still
#     works.
check_7() {
	run_file "${ROLLBACK}" || {
		note "the rollback failed"
		return 1
	}
	run_file "${ROLLBACK}" || {
		note "the second rollback failed"
		return 1
	}
	for obj in ai_rec_models ai_rec_item_factors ai_rec_user_factors; do
		left="$(q "SELECT to_regclass('public.${obj}') IS NOT NULL;")"
		[ "${left}" = "f" ] || {
			DETAIL="public.${obj} survived the rollback"
			return 1
		}
	done
	for call in "public.ai_rec_promote(bigint,boolean)" "public.ai_rec_prune(integer)" \
		"public.ai_rec_erase_user(uuid)"; do
		left="$(q "SELECT to_regprocedure('${call}') IS NOT NULL;")"
		[ "${left}" = "f" ] || {
			DETAIL="${call} survived the rollback"
			return 1
		}
	done
	# The events file is still valid: its call to the erasure is guarded.
	run_sql "SELECT public.ai_erase_user('${U2}');" || {
		DETAIL="ai_erase_user failed after the rollback: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	# The migration is applied again: the database is left as the file found
	# it, and the re-apply proves the rollback is a real inverse.
	apply_migration || {
		note "the re-apply after the rollback failed"
		return 1
	}
	DESCR="the rollback (twice) leaves none of the new objects, and ai_erase_user still runs"
	return 0
}

main() {
	start_pg
	note "postgres up in ${CTN}"
	apply_fixture || {
		note "the fixture failed"
		exit 1
	}
	note "fixture applied (the migration twice, the events-only database beside it)"

	for fn in check_0 check_1 check_2 check_3 check_4 check_5 check_6 check_7; do
		DETAIL=""
		DESCR=""
		if "${fn}"; then
			pass "${fn}" "${DESCR:-the check passed}"
		else
			fail "${fn}" "${DETAIL:-the check failed}"
		fi
	done

	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
