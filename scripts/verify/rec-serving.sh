#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    rec-serving.sh                                                            #
#                                                                              #
#    Prove the two reads that serve the champion: a user's context for the    #
#    fold-in, and the champion's nearest items through the HNSW index.        #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-rec-serving-migration.sql)
#   1  the context: an opted-out user with events gets EXACTLY
#      {"opted_out": true}; no champion gets {"model": null}; a user with a
#      stored vector gets its 16 numbers and not its 64; a new user with 3
#      liked items and one not_interested item gets the 3 items with their
#      per-event counts and their 16-number vectors, the other one in
#      not_interested, and NOT the synthetic event
#   2  the nearest: on a champion of 2,000 items plus two other models of
#      2,000 items each in the same table, p_limit 50 gives exactly 50 rows,
#      all of the champion's model, ordered by score descending, with the
#      scores equal to the inner products computed in SQL without the index
#      (1e-5), and the top-20 equal to the exact top-20 (the recall is
#      printed)
#   3  the EXPLAIN (enable_seqscan = off) of the function's query names the
#      HNSW index
#   4  a 65-number vector is refused with 22023, a kind that is not page or
#      user is refused, and anon and authenticated cannot execute either
#      function
#   5  the rollback (twice) leaves the two functions gone and the factors
#      file's objects untouched
#
# THE FIXTURE
#   The roles of scripts/verify/models-grants/roles.sql, then the PRE-1e407614
#   default privileges (anon and authenticated get everything on every table
#   created from here on) so that the migration's own REVOKE is what closes
#   them — otherwise check 4 would pass for the wrong reason. Then the
#   prerequisite models, then the events migration (the log and the opt-out),
#   then the factors migration (the registry, the factors and the HNSW
#   index), then the migration itself TWICE.
#
#   A SECOND DATABASE (the same container) holds the factors migration and
#   the serving migration WITHOUT the events migration: that is what proves
#   the serving file does not need the events file to be applied — the events
#   tables are read at CALL time, not at creation time.
#
# ISOLATION
#   Throwaway containers only: rec-srv-pg, --network none, no port, no
#   volume. The live mini-baas / osionos containers are never touched. The
#   container is removed on every exit path.
#
# Usage:  sh scripts/verify/rec-serving.sh [--keep]
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
MIGRATION="osionos-rec-serving-migration.sql"
FACTORS="osionos-rec-factors-migration.sql"
EVENTS="osionos-user-events-migration.sql"
ROLLBACK="${MODELS}/rollback/osionos-rec-serving-rollback.sql"
CTN="rec-srv-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
ALONE_DB="rec_serving_standalone"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rec-serving.XXXXXX")"
passed=0
failed=0
DETAIL=""
DESCR=""
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# The test data. Three users, so no check can see another's rows: U_OPT is
# the opted-out one, U_VEC is the user the model has seen, and U_NEW is the
# user the model has NOT seen (the one the bridge folds in).
U_OPT=11111111-1111-1111-1111-111111111111
U_VEC=22222222-2222-2222-2222-222222222222
U_NEW=33333333-3333-3333-3333-333333333333
WS=44444444-4444-4444-4444-444444444444

# The items the events of check 1 talk about. They are the champion's items
# 1 to 5, so they carry a vector.
I1=00000000-0000-4000-8000-000000000001
I2=00000000-0000-4000-8000-000000000002
I3=00000000-0000-4000-8000-000000000003
I4=00000000-0000-4000-8000-000000000004
I5=00000000-0000-4000-8000-000000000005

# The 16 REAL coordinates of the champion: the model has 16 factors and the
# stored vectors are 64-dimensional, zero-padded past the 16. The user
# vector of check 1 is these numbers, so the expected JSON is known outside
# the database.
VEC16="0.5 -0.25 0.125 1.5 -2 0.75 3.25 -0.5 0 1.125 -1.75 2.5 0.375 -0.625 4 0.0625"
VEC16_JSON="[0.5,-0.25,0.125,1.5,-2,0.75,3.25,-0.5,0,1.125,-1.75,2.5,0.375,-0.625,4,0.0625]"

note() { printf '[rec-serving] %s\n' "$*" >&2; }
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

# q_db <db> <sql> — the same, on another database.
q_db() {
	printf '%s\n' "$2" | psql_db "$1" 2>/dev/null || true
}

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

# apply_migration — the serving migration, once.
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
	# REVOKE has to close them, or check 4 would pass for the wrong reason.
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
	# The events migration: the log and the opt-out of check 1.
	apply_file "${MODELS}/${EVENTS}" || {
		note "the fixture could not apply the events migration"
		return 1
	}
	# The factors migration: the registry, the factors and the HNSW index.
	apply_file "${MODELS}/${FACTORS}" || {
		note "the fixture could not apply the factors migration"
		return 1
	}
	# The migration, twice.
	apply_migration || return 1
	apply_migration || return 1
	return 0
}

# The standalone database: the factors migration and the serving migration,
# WITHOUT the events migration. It is what proves the serving file does not
# need the events file to be applied.
apply_standalone_db() {
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "DROP DATABASE IF EXISTS ${ALONE_DB};" >"${WORK}/apply.log" 2>&1 || return 1
	docker exec "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		-c "CREATE DATABASE ${ALONE_DB};" >>"${WORK}/apply.log" 2>&1 || return 1
	# The roles are cluster-wide and are already there; the schema and its
	# grants are per-database.
	printf 'CREATE SCHEMA IF NOT EXISTS auth;\nGRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;\nGRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;\nALTER ROLE postgres IN DATABASE %s SET search_path = auth, public;\n' \
		"${ALONE_DB}" | psql_db "${ALONE_DB}" >"${WORK}/apply.log" 2>&1 || return 1
	apply_file_db "${ALONE_DB}" "${MODELS}/${FACTORS}" || return 1
	apply_file_db "${ALONE_DB}" "${MODELS}/${MIGRATION}" || return 1
	apply_file_db "${ALONE_DB}" "${MODELS}/${MIGRATION}" || return 1
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

# 0 — the runner applies the migration AFTER the factors file, and the
#     migration stands without the events migration.
#
#     The header says the file sorts after the factors file because the SQL
#     function's body is validated at creation, and before the events file
#     because the events tables are read at CALL time. Both claims are
#     proved here, not asserted.
check_0() {
	order="$(runner_alphabetical)"
	mine="$(printf '%s\n' "${order}" | grep -n "^${MIGRATION}\$" | cut -d: -f1 || true)"
	[ -n "${mine}" ] || {
		DETAIL="${MIGRATION} is not in the runner's alphabetical pass"
		return 1
	}
	factors="$(printf '%s\n' "${order}" | grep -n "^${FACTORS}\$" | cut -d: -f1 || true)"
	[ -n "${factors}" ] || {
		DETAIL="${FACTORS} is not in the runner's alphabetical pass"
		return 1
	}
	[ "${factors}" -lt "${mine}" ] || {
		DETAIL="${FACTORS} is applied at ${factors} and ${MIGRATION} at ${mine}: the factor tables must exist first"
		return 1
	}
	# The standalone database: the factors migration and the serving
	# migration, twice, WITHOUT the events migration.
	apply_standalone_db || {
		DETAIL="the standalone database could not be prepared"
		return 1
	}
	for call in "public.ai_rec_user_context(uuid,integer)" \
		"public.ai_rec_nearest(bigint,real[],integer,text)" \
		"public.ai_rec_nearest_rows(bigint,vector,integer,text,smallint)"; do
		left="$(q_db "${ALONE_DB}" "SELECT to_regprocedure('${call}') IS NOT NULL;")"
		[ "${left}" = "t" ] || {
			DETAIL="${call} is missing on the database without the events migration"
			return 1
		}
	done
	DESCR="the runner applies the migration after the factors file, and it applies twice without the events migration"
	return 0
}

# 1 — the context: the opt-out, the champion, the user's vector, the recent
#     items and the not-interested ones.
check_1() {
	# No champion yet: there is no model to score anybody with.
	out="$(q "SELECT public.ai_rec_user_context('${U_NEW}');")"
	[ "${out}" = '{"model": null}' ] || {
		DETAIL="with no champion the context is ${out:-nothing}, expected {\"model\": null}"
		return 1
	}

	# The champion: 16 factors, so the vectors are 16 real numbers padded to
	# 64. It is promoted the way the factors file promotes a model.
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha)
VALUES ('ials', 16, 0.1, 0.01, 10, 2000, now(), '{\"ndcg10\": 0.31}'::jsonb, false, 'e1e1e1e');" || {
		note "the champion model failed"
		return 1
	}
	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'e1e1e1e';")"
	[ -n "${mid}" ] || {
		DETAIL="the champion model is not in the registry"
		return 1
	}
	out="$(q "SELECT public.ai_rec_promote(${mid});")"
	[ "${out}" = "promoted" ] || {
		DETAIL="the promotion returned ${out:-nothing}, expected promoted"
		return 1
	}

	# The champion's 2,000 items. The vectors are deterministic (md5 of the
	# item and the coordinate), and only the first 16 of the 64 coordinates
	# are real: the model has 16 factors.
	run_sql "INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors)
SELECT ${mid}, 'page', ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
       ('[' || (SELECT string_agg(CASE WHEN d <= 16
                 THEN (((('x' || substr(md5('champ:' || i::text || ':' || d::text), 1, 8))::bit(32)::int
                        + 2147483648)::double precision / 4294967295.0) * 2 - 1)::real::text
                 ELSE '0' END, ',' ORDER BY d)
                 FROM generate_series(1, 64) d) || ']')::vector
  FROM generate_series(1, 2000) i;" || {
		note "the champion's 2,000 items failed"
		return 1
	}
	run_sql "ANALYZE public.ai_rec_item_factors;" || {
		note "the analyze failed"
		return 1
	}

	# The user the model has seen: its vector is the 16 known numbers,
	# padded to 64.
	run_sql "INSERT INTO public.ai_rec_user_factors (model_id, user_id, factors) VALUES (${mid}, '${U_VEC}', '$(pad "${VEC16}")'::vector);" || {
		note "the user vector failed"
		return 1
	}

	# The opt-out, and the events of the three users.
	run_sql "INSERT INTO public.ai_personalization_settings (user_id, capture_explicit) VALUES ('${U_OPT}', false);
INSERT INTO public.ai_events (ts, user_id, item_kind, item_id, workspace_id, event, is_synthetic) VALUES
  (now() - interval '1 hour',   '${U_OPT}', 'page', '${I1}', '${WS}', 'like',            false),
  (now() - interval '1 hour',   '${U_NEW}', 'page', '${I1}', '${WS}', 'like',            false),
  (now() - interval '2 hours',  '${U_NEW}', 'page', '${I1}', '${WS}', 'like',            false),
  (now() - interval '3 hours',  '${U_NEW}', 'page', '${I1}', '${WS}', 'share',           false),
  (now() - interval '1 day',    '${U_NEW}', 'page', '${I2}', '${WS}', 'like',            false),
  (now() - interval '2 days',   '${U_NEW}', 'page', '${I3}', '${WS}', 'react',           false),
  (now() - interval '3 days',   '${U_NEW}', 'page', '${I4}', '${WS}', 'not_interested',  false),
  (now() - interval '4 days',   '${U_NEW}', 'page', '${I5}', '${WS}', 'like',            true),
  (now() - interval '200 days', '${U_NEW}', 'page', '${I1}', '${WS}', 'like',            false);" || {
		note "the settings and the events failed"
		return 1
	}

	# The opted-out user gets EXACTLY {"opted_out": true}: the events are
	# there, and they are not in the answer.
	out="$(q "SELECT public.ai_rec_user_context('${U_OPT}');")"
	[ "${out}" = '{"opted_out": true}' ] || {
		DETAIL="the opted-out context is ${out:-nothing}, expected {\"opted_out\": true}"
		return 1
	}

	# The user the model has seen: the model, and its 16 numbers.
	out="$(q "SELECT (public.ai_rec_user_context('${U_VEC}') -> 'model' ->> 'id') = '${mid}';")"
	[ "${out}" = "t" ] || {
		DETAIL="the context names another model: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_VEC}') -> 'model' ->> 'factors') = '16';")"
	[ "${out}" = "t" ] || {
		DETAIL="the context says another factor count: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_VEC}') -> 'user_vector');")"
	[ "${out}" = "16" ] || {
		DETAIL="the user vector has ${out:-no} number(s), expected 16"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_VEC}') -> 'user_vector') = '${VEC16_JSON}'::jsonb;")"
	[ "${out}" = "t" ] || {
		DETAIL="the user vector is not the 16 stored numbers"
		return 1
	}
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_VEC}') -> 'recent');")"
	[ "${out}" = "0" ] || {
		DETAIL="the user with no events has ${out:-no} recent item(s)"
		return 1
	}

	# The new user: three liked items, one not interested, one synthetic.
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_NEW}') -> 'recent');")"
	[ "${out}" = "3" ] || {
		DETAIL="the recent list has ${out:-no} item(s), expected 3"
		return 1
	}
	# The most recently touched item is first, and its events are counted.
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 0 ->> 'item_id') = '${I1}';")"
	[ "${out}" = "t" ] || {
		DETAIL="the first recent item is not ${I1}: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 0 -> 'events') = '{\"like\": 2, \"share\": 1}'::jsonb;")"
	[ "${out}" = "t" ] || {
		DETAIL="the events of the first item are not {like: 2, share: 1}: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 1 ->> 'item_id') = '${I2}';")"
	[ "${out}" = "t" ] || {
		DETAIL="the second recent item is not ${I2}: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 2 ->> 'item_id') = '${I3}';")"
	[ "${out}" = "t" ] || {
		DETAIL="the third recent item is not ${I3}: ${out:-nothing}"
		return 1
	}
	# The item's vector: the champion's, in its 16 true dimensions.
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 0 -> 'vector');")"
	[ "${out}" = "16" ] || {
		DETAIL="the item vector has ${out:-no} number(s), expected 16"
		return 1
	}
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 0 -> 'vector') =
  (SELECT to_jsonb((SELECT array_agg(x::real ORDER BY o)
                      FROM unnest(string_to_array(trim(both '[]' from f.factors::text), ','))
                           WITH ORDINALITY AS t(x, o)
                     WHERE o <= 16))
     FROM public.ai_rec_item_factors f
    WHERE f.model_id = ${mid} AND f.item_kind = 'page' AND f.item_id = '${I1}');")"
	[ "${out}" = "t" ] || {
		DETAIL="the item vector is not the champion's first 16 numbers"
		return 1
	}
	# The not-interested item is in the other list, and NOT in the recent one.
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'not_interested') = '[{\"item_kind\": \"page\", \"item_id\": \"${I4}\"}]'::jsonb;")"
	[ "${out}" = "t" ] || {
		DETAIL="the not_interested list is not the one item: ${out:-nothing}"
		return 1
	}
	out="$(q "SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.ai_rec_user_context('${U_NEW}') -> 'recent') r WHERE r ->> 'item_id' = '${I4}');")"
	[ "${out}" = "t" ] || {
		DETAIL="the not-interested item is in the recent list"
		return 1
	}
	# The synthetic event is not a preference: its item is nowhere.
	out="$(q "SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.ai_rec_user_context('${U_NEW}') -> 'recent') r WHERE r ->> 'item_id' = '${I5}');")"
	[ "${out}" = "t" ] || {
		DETAIL="the synthetic event is in the recent list"
		return 1
	}
	# The event older than 180 days is not counted: the first item has 2 likes
	# and not 3.
	out="$(q "SELECT (public.ai_rec_user_context('${U_NEW}') -> 'recent' -> 0 -> 'events' ->> 'like') = '2';")"
	[ "${out}" = "t" ] || {
		DETAIL="the 200-day-old event was counted: ${out:-nothing}"
		return 1
	}
	# p_recent is clamped: 1 at least.
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_NEW}', 1) -> 'recent');")"
	[ "${out}" = "1" ] || {
		DETAIL="p_recent 1 returned ${out:-no} item(s)"
		return 1
	}
	out="$(q "SELECT jsonb_array_length(public.ai_rec_user_context('${U_NEW}', 0) -> 'recent');")"
	[ "${out}" = "1" ] || {
		DETAIL="p_recent 0 returned ${out:-no} item(s), expected the clamped 1"
		return 1
	}
	DESCR="the opted-out user gets nothing else, no champion gives {\"model\": null}, the new user gets its 3 items with their counts and their 16-number vectors"
	return 0
}

# 2 — the nearest items: the champion's rows, on the HNSW index, with the
#     other models' rows in the same table.
check_2() {
	# Two other models, 2,000 items each: the retired ones and the
	# candidates share the index with the champion, which is the whole
	# point of the iterative scan.
	run_sql "INSERT INTO public.ai_rec_models (algo, factors, regularization, alpha, iterations, events_used, trained_until, metrics, is_synthetic, code_sha, status) VALUES
  ('ials', 64, 0.1, 0.01, 10, 2000, now(), '{\"ndcg10\": 0.29}'::jsonb, false, 'e2e2e2e', 'retired'),
  ('ials', 64, 0.1, 0.01, 10, 2000, now(), '{\"ndcg10\": 0.28}'::jsonb, false, 'e3e3e3e', 'retired');" || {
		note "the two other models failed"
		return 1
	}
	run_sql "INSERT INTO public.ai_rec_item_factors (model_id, item_kind, item_id, factors)
SELECT m.id, 'page', ('00000000-0000-4000-9000-' || lpad((m.id * 10000 + i)::text, 12, '0'))::uuid,
       ('[' || (SELECT string_agg((((('x' || substr(md5(m::text || ':' || i::text || ':' || d::text), 1, 8))::bit(32)::int
                        + 2147483648)::double precision / 4294967295.0) * 2 - 1)::real::text, ',' ORDER BY d)
                 FROM generate_series(1, 64) d) || ']')::vector
  FROM public.ai_rec_models m CROSS JOIN generate_series(1, 2000) i
 WHERE m.code_sha IN ('e2e2e2e', 'e3e3e3e');" || {
		note "the 4,000 items of the other models failed"
		return 1
	}
	run_sql "ANALYZE public.ai_rec_item_factors;" || {
		note "the analyze failed"
		return 1
	}

	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'e1e1e1e';")"
	# The query vector: the champion's own item 100, so the search asks for
	# something the model really knows.
	qv_text="$(q "SELECT factors::text FROM public.ai_rec_item_factors WHERE model_id = ${mid} AND item_kind = 'page' AND item_id = '00000000-0000-4000-8000-000000000100';")"
	[ -n "${qv_text}" ] || {
		DETAIL="the champion's item 100 is missing"
		return 1
	}
	qv_arr="{$(printf '%s' "${qv_text}" | tr -d '[]')}"
	qv_vec="${qv_text}"

	# Exactly 50 rows: the iterative scan is what makes a filtered search
	# reach the LIMIT it was asked for.
	n="$(q "SELECT count(*) FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 50, 'page');")"
	[ "${n}" = "50" ] || {
		DETAIL="the search returned ${n:-no} row(s), expected 50"
		return 1
	}
	# All of them are the champion's rows.
	n="$(q "SELECT count(*) FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 50, 'page') r
 WHERE NOT EXISTS (SELECT 1 FROM public.ai_rec_item_factors f
                    WHERE f.model_id = ${mid} AND f.item_kind = r.item_kind AND f.item_id = r.item_id);")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} row(s) are not the champion's"
		return 1
	}
	# The scores come down.
	n="$(q "SELECT count(*) FROM (
  SELECT r.score, lag(r.score) OVER (ORDER BY r.ord) AS prev
    FROM (SELECT row_number() OVER () AS ord, score FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 50, 'page')) r
) t WHERE t.prev IS NOT NULL AND t.score > t.prev;")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} row(s) are out of order"
		return 1
	}
	# The scores are the inner products, computed WITHOUT the index.
	n="$(printf '%s\n' "SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT count(*) FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 50, 'page') r
  JOIN public.ai_rec_item_factors f ON f.model_id = ${mid} AND f.item_kind = r.item_kind AND f.item_id = r.item_id
 WHERE abs(r.score - (-(f.factors <#> '${qv_vec}'::vector(64)))) > 1e-5;" |
		psql_q 2>/dev/null || true)"
	[ "${n}" = "0" ] || {
		DETAIL="${n} score(s) are not the inner product of the row"
		return 1
	}
	# The top-20 is the exact top-20. The exact one is computed with the
	# index off: a scan and a sort.
	printf '%s\n' "SET hnsw.iterative_scan = 'relaxed_order'; SET hnsw.ef_search = 100;
SELECT item_id FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 20, 'page');" |
		psql_q 2>/dev/null | sort >"${WORK}/hnsw.txt" || true
	printf '%s\n' "SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT item_id FROM public.ai_rec_item_factors WHERE model_id = ${mid} AND item_kind = 'page'
 ORDER BY factors <#> '${qv_vec}'::vector(64) LIMIT 20;" |
		psql_q 2>/dev/null | sort >"${WORK}/exact.txt" || true
	hits="$(comm -12 "${WORK}/hnsw.txt" "${WORK}/exact.txt" | wc -l | tr -d ' ')"
	[ "${hits}" = "20" ] || {
		DETAIL="the HNSW top-20 and the exact top-20 share ${hits} row(s), expected 20"
		return 1
	}
	DESCR="50 rows of the champion on the index, the scores are the inner products, the top-20 is the exact top-20 (recall ${hits}/20)"
	return 0
}

# 3 — the EXPLAIN of the function's query names the HNSW index.
check_3() {
	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'e1e1e1e';")"
	qv_vec="$(q "SELECT factors::text FROM public.ai_rec_item_factors WHERE model_id = ${mid} AND item_kind = 'page' AND item_id = '00000000-0000-4000-8000-000000000100';")"
	run_sql "SET enable_seqscan = off;
EXPLAIN SELECT * FROM public.ai_rec_nearest_rows(${mid}, '${qv_vec}'::vector(64), 50, 'page', 16::smallint);" || {
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
	DESCR="the plan of the function's query names the HNSW index"
	return 0
}

# 4 — the refusals: a vector that is too long, a kind that does not exist,
#     and the two roles that may not call either function.
check_4() {
	mid="$(q "SELECT id FROM public.ai_rec_models WHERE code_sha = 'e1e1e1e';")"
	qv_arr="{$(printf '%s' "$(q "SELECT factors::text FROM public.ai_rec_item_factors WHERE model_id = ${mid} AND item_kind = 'page' AND item_id = '00000000-0000-4000-8000-000000000100';")" | tr -d '[]')}"

	# 65 numbers: the model's vector has 64 dimensions at most.
	st="$(state_of "SELECT public.ai_rec_nearest(${mid}, array_fill(0.1::real, ARRAY[65]), 10, 'page');")"
	[ "${st}" = "22023" ] || {
		DETAIL="a 65-number vector was refused with ${st:-no error}, expected 22023"
		return 1
	}
	# A kind that is neither page nor user.
	st="$(state_of "SELECT public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 10, 'x');")"
	[ -n "${st}" ] || {
		DETAIL="the kind 'x' was accepted"
		return 1
	}
	# anon and authenticated may not execute either function.
	for role in anon authenticated; do
		for call in "public.ai_rec_user_context('${U_NEW}')" \
			"public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 10, 'page')"; do
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
	# The positive control: service_role may.
	run_sql "SET ROLE service_role; SELECT public.ai_rec_user_context('${U_NEW}'); SELECT count(*) FROM public.ai_rec_nearest(${mid}, '${qv_arr}'::real[], 10, 'page');" || {
		DETAIL="service_role could not use the serving functions: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	DESCR="a 65-number vector is 22023, a kind that does not exist is refused, anon and authenticated are refused, service_role may"
	return 0
}

# 5 — the rollback: the two functions are gone, the factors file's objects are
#     untouched.
check_5() {
	before_models="$(q "SELECT count(*) FROM public.ai_rec_models;")"
	before_items="$(q "SELECT count(*) FROM public.ai_rec_item_factors;")"
	before_users="$(q "SELECT count(*) FROM public.ai_rec_user_factors;")"
	run_file "${ROLLBACK}" || {
		note "the rollback failed"
		return 1
	}
	run_file "${ROLLBACK}" || {
		note "the second rollback failed"
		return 1
	}
	for call in "public.ai_rec_user_context(uuid,integer)" \
		"public.ai_rec_nearest(bigint,real[],integer,text)" \
		"public.ai_rec_nearest_rows(bigint,vector,integer,text,smallint)"; do
		left="$(q "SELECT to_regprocedure('${call}') IS NOT NULL;")"
		[ "${left}" = "f" ] || {
			DETAIL="${call} survived the rollback"
			return 1
		}
	done
	# The factors file's objects are untouched: the tables, their rows and
	# the HNSW index.
	for obj in ai_rec_models ai_rec_item_factors ai_rec_user_factors; do
		left="$(q "SELECT to_regclass('public.${obj}') IS NOT NULL;")"
		[ "${left}" = "t" ] || {
			DETAIL="public.${obj} did not survive the rollback"
			return 1
		}
	done
	left="$(q "SELECT count(*) FROM public.ai_rec_models;")"
	[ "${left}" = "${before_models}" ] || {
		DETAIL="the registry has ${left} model(s), expected ${before_models}"
		return 1
	}
	left="$(q "SELECT count(*) FROM public.ai_rec_item_factors;")"
	[ "${left}" = "${before_items}" ] || {
		DETAIL="the item factors have ${left} row(s), expected ${before_items}"
		return 1
	}
	left="$(q "SELECT count(*) FROM public.ai_rec_user_factors;")"
	[ "${left}" = "${before_users}" ] || {
		DETAIL="the user factors have ${left} row(s), expected ${before_users}"
		return 1
	}
	left="$(q "SELECT count(*) FROM pg_indexes WHERE indexname = 'ai_rec_item_factors_hnsw_idx';")"
	[ "${left}" = "1" ] || {
		DETAIL="the HNSW index did not survive the rollback"
		return 1
	}
	# The migration is applied again: the database is left as the file found
	# it, and the re-apply proves the rollback is a real inverse.
	apply_migration || {
		note "the re-apply after the rollback failed"
		return 1
	}
	DESCR="the rollback (twice) leaves the two functions gone and the factors file's objects untouched"
	return 0
}

main() {
	start_pg
	note "postgres up in ${CTN}"
	apply_fixture || {
		note "the fixture failed"
		exit 1
	}
	note "fixture applied (the migration twice)"

	for fn in check_0 check_1 check_2 check_3 check_4 check_5; do
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
