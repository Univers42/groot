#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-events.sh                                                             #
#                                                                              #
#    Prove the ai_events log: the capture triggers, the opt-out, the failure   #
#    isolation, the partitions, the grants, the erasure and the rollback.      #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-user-events-migration.sql)
#   1  a like on a live page -> exactly one row, with the page's workspace
#   2  a like on a ghost page id -> the like succeeds, no row
#   3  three favorites in ONE statement -> three rows
#   4  a page delete cascading 1,000 favorites -> no new row
#   5  500 colleague edges -> no row; a manual connection accepted -> two rows
#   6  the opt-out (capture_explicit = false) -> the like succeeds, no row
#   7  SET osionos.ai_events = 'off' -> no row
#   8  the capture broken (the table renamed) -> the like still succeeds, with
#      a warning
#   9  a row in a month with no partition -> the DEFAULT partition; one
#      ai_events_maintain() pass creates the missing months and drops an old one
#   10 anon and authenticated are refused; the column list is exactly the one
#      the brief names
#   11 ai_export_user holds every row of the user and none of another user's;
#      ai_erase_user empties every partition, writes no event, and keeps the
#      settings row
#   12 the rollback (twice) leaves the engagement tables exactly as they were
#      before the migration
#   13 the p95 of 1,000 single-row likes, with the trigger and without
#
# THE FIXTURE
#   The roles of scripts/verify/models-grants/roles.sql, then the PRE-1e407614
#   default privileges (anon and authenticated get everything on every table
#   created from here on) so that the migration's own REVOKE is what closes
#   them — otherwise check 10 would pass for the wrong reason. Then the
#   prerequisite models, then the migration itself TWICE.
#
# ISOLATION
#   Throwaway containers only: ai-ev-pg, --network none, no port, no volume. The
#   live mini-baas / osionos containers are never touched. The container is
#   removed on every exit path.
#
# Usage:  sh scripts/verify/ai-events.sh [--keep]
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
MIGRATION="osionos-user-events-migration.sql"
ROLLBACK="${MODELS}/rollback/osionos-user-events-rollback.sql"
CTN="ai-ev-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-events.XXXXXX")"
passed=0
failed=0
DETAIL=""
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# The test data. Five users, so no check can see another's rows.
WS=11111111-1111-1111-1111-111111111111
P1=22222222-2222-2222-2222-222222222221
P2=22222222-2222-2222-2222-222222222222
P3=22222222-2222-2222-2222-222222222223
GHOST=99999999-9999-9999-9999-999999999999
U1=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
U2=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
U3=cccccccc-cccc-cccc-cccc-cccccccccccc
U4=dddddddd-dddd-dddd-dddd-dddddddddddd
U5=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee

note() { printf '[ai-events] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS: %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s %s\n' "$1" "$2"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: container ${CTN} left up"; return 0; }
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }

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

apply_file() {
	if docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		<"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
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

# The schema of the engagement tables — the ones the capture observes. The
# \restrict token is random per dump (pg_dump 16.10+), so it is filtered out:
# it is not a schema difference.
dump_engagement() {
	docker exec "${CTN}" pg_dump -U postgres -d postgres --schema-only \
		-t 'public.osionos_feed_likes' \
		-t 'public.osionos_feed_reactions' \
		-t 'public.osionos_feed_shares' \
		-t 'public.osionos_feed_comments' \
		-t 'public.osionos_page_comments' \
		-t 'public.osionos_page_favorites' \
		-t 'public.osionos_connections' >"${WORK}/raw.dump" 2>"${WORK}/dump.err" || return 1
	grep -v '^\\\(un\)\?restrict ' "${WORK}/raw.dump" >"${WORK}/dump.out" || true
	cat "${WORK}/dump.out"
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

# The migration captures from tables other files create. The alphabetical pass
# is the only slot both runners share, so the file is NAMED to sort after them
# (see the migration's header). This reads the runner's order instead of
# trusting the name: a file that moved would break the capture on a fresh
# database, and only the order says so.
check_runner_order() {
	order="$(runner_alphabetical)"
	mine="$(printf '%s\n' "${order}" | grep -n "^${MIGRATION}\$" | cut -d: -f1 || true)"
	[ -n "${mine}" ] || {
		note "${MIGRATION} is not in the runner's alphabetical pass"
		return 1
	}
	for need in osionos-bridge-migration.sql osionos-chat-migration.sql \
		osionos-comments-migration.sql osionos-favorites-migration.sql \
		osionos-feed-engagement-migration.sql osionos-social-migration.sql; do
		at="$(printf '%s\n' "${order}" | grep -n "^${need}\$" | cut -d: -f1 || true)"
		# A file of ORDERED_FIRST is not in the alphabetical pass: it is applied
		# before it, so it is before the migration too.
		[ -z "${at}" ] && at=0
		[ "${at}" -lt "${mine}" ] || {
			note "${need} is applied after ${MIGRATION} — the capture would fail on a fresh database"
			return 1
		}
	done
	return 0
}

apply_migration() { apply_file "${MODELS}/${MIGRATION}"; }

apply_fixture() {
	apply_file "${FIX}/roles.sql" || return 1
	# The live stack's search_path: grobase's 001_initial_schema.sql sets it on
	# the postgres role, and it starts with auth. A relation created without a
	# schema lands in the FIRST schema of the search_path, so this fixture would
	# have put every partition in the auth schema — the migration has to spell
	# the schema out.
	printf 'ALTER ROLE postgres IN DATABASE postgres SET search_path = auth, public;\n' |
		docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/apply.log" 2>&1 || {
		note "the search_path could not be set"
		return 1
	}
	# The pre-1e407614 default privileges: anon and authenticated get
	# everything on every table created from here on. The migration's own
	# REVOKE has to close them, or check 10 would pass for the wrong reason.
	printf 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;\n' |
		docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/apply.log" 2>&1 || {
		note "the legacy default privileges failed"
		return 1
	}
	# The prerequisite models, in the order they need each other (the runner's
	# ORDERED_FIRST first, then the alphabetical pass).
	set -- osionos-bridge-migration.sql osionos-chat-migration.sql \
		osionos-social-migration.sql osionos-engagement-migration.sql \
		osionos-comments-migration.sql osionos-favorites-migration.sql \
		osionos-feed-engagement-migration.sql
	for base in "$@"; do
		apply_file "${MODELS}/${base}" || {
			note "the fixture could not apply ${base}"
			return 1
		}
	done
	# The schema of the engagement tables, BEFORE the migration touched them.
	dump_engagement >"${WORK}/before.dump" || {
		note "the first dump failed"
		return 1
	}
	# The migration, twice.
	apply_migration || return 1
	apply_migration || return 1
	# The test data: one workspace, three live pages.
	run_sql "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${WS}', '${U1}', 'ws1', 'ws1');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES ('${P1}', '${WS}', '${U1}', 'p1'), ('${P2}', '${WS}', '${U1}', 'p2'), ('${P3}', '${WS}', '${U1}', 'p3');" || {
		note "the test data failed"
		return 1
	}
	return 0
}

# --- the checks ------------------------------------------------------------

check_1() {
	run_sql "INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${P1}', '${U1}');" || {
		note "the like failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE event = 'like' AND user_id = '${U1}';")"
	w="$(q "SELECT coalesce(min(workspace_id::text), '') FROM public.ai_events WHERE event = 'like' AND user_id = '${U1}';")"
	[ "${n}" = "1" ] && [ "${w}" = "${WS}" ] && return 0
	DETAIL="${n} row(s), workspace_id ${w:-none}"
	return 1
}

check_2() {
	run_sql "INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${GHOST}', '${U1}');" || {
		note "the like on a ghost page id failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE item_id = '${GHOST}';")"
	[ "${n}" = "0" ] && return 0
	DETAIL="${n} row(s) for a ghost page id"
	return 1
}

check_3() {
	run_sql "INSERT INTO public.osionos_page_favorites (user_id, page_id) VALUES ('${U1}','${P1}'), ('${U1}','${P2}'), ('${U1}','${P3}');" || {
		note "the three favorites failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE event = 'favorite' AND user_id = '${U1}';")"
	[ "${n}" = "3" ] && return 0
	DETAIL="${n} row(s) for three favorites in one statement"
	return 1
}

check_4() {
	run_sql "INSERT INTO public.osionos_page_favorites (user_id, page_id) SELECT ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, '${P3}' FROM generate_series(1, 1000) i;" || {
		note "the 1,000 favorites failed"
		return 1
	}
	before="$(q "SELECT count(*) FROM public.ai_events;")"
	run_sql "DELETE FROM public.osionos_pages WHERE id = '${P3}';" || {
		note "the page delete failed"
		return 1
	}
	after="$(q "SELECT count(*) FROM public.ai_events;")"
	left="$(q "SELECT count(*) FROM public.osionos_page_favorites WHERE page_id = '${P3}';")"
	[ "${left}" = "0" ] || {
		DETAIL="${left} favorites survived the delete"
		return 1
	}
	[ "${before}" = "${after}" ] && return 0
	DETAIL="${before} -> ${after} rows: the cascade captured something"
	return 1
}

check_5() {
	run_sql "INSERT INTO public.osionos_connections (requester_id, addressee_id, status, source) SELECT ('10000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, ('20000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, 'accepted', 'colleague' FROM generate_series(1, 500) i;" || {
		note "the 500 colleague edges failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE event = 'connect';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} connect row(s) from colleague edges"
		return 1
	}
	run_sql "INSERT INTO public.osionos_connections (requester_id, addressee_id, status, source) VALUES ('${U1}', '${U2}', 'pending', 'manual');" || {
		note "the manual connection failed"
		return 1
	}
	run_sql "UPDATE public.osionos_connections SET status = 'accepted' WHERE requester_id = '${U1}' AND addressee_id = '${U2}';" || {
		note "the accept failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE event = 'connect';")"
	sides="$(q "SELECT count(DISTINCT user_id) FROM public.ai_events WHERE event = 'connect';")"
	[ "${n}" = "2" ] && [ "${sides}" = "2" ] && return 0
	DETAIL="${n} connect row(s) for one manual accept, ${sides} side(s)"
	return 1
}

check_6() {
	run_sql "INSERT INTO public.ai_personalization_settings (user_id, capture_explicit, beacon_consent) VALUES ('${U1}', false, true) ON CONFLICT (user_id) DO UPDATE SET capture_explicit = false;" || {
		note "the opt-out row failed"
		return 1
	}
	before="$(q "SELECT count(*) FROM public.ai_events WHERE user_id = '${U1}';")"
	run_sql "INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${P2}', '${U1}');" || {
		note "the like of an opted-out user failed"
		return 1
	}
	after="$(q "SELECT count(*) FROM public.ai_events WHERE user_id = '${U1}';")"
	[ "${before}" = "${after}" ] && return 0
	DETAIL="${before} -> ${after} rows: the opt-out was ignored"
	return 1
}

check_7() {
	run_sql "BEGIN; SET LOCAL osionos.ai_events = 'off'; INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${P2}', '${U3}'); COMMIT;" || {
		note "the like with the capture off failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_events WHERE user_id = '${U3}';")"
	[ "${n}" = "0" ] && return 0
	DETAIL="${n} row(s) with the capture off"
	return 1
}

check_8() {
	run_sql "ALTER TABLE public.ai_events RENAME TO ai_events_moved;" || {
		note "the rename failed"
		return 1
	}
	landed=0
	run_sql "INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${P1}', '${U4}');" && landed=1
	warned=0
	grep -q 'ai_events capture skipped' "${WORK}/sql.err" && warned=1
	run_sql "ALTER TABLE public.ai_events_moved RENAME TO ai_events;" || {
		note "the rename back failed"
		return 1
	}
	[ "${landed}" = "1" ] || {
		DETAIL="the like failed while the capture was broken"
		return 1
	}
	[ "${warned}" = "1" ] || {
		DETAIL="the capture failed silently — no warning was printed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.osionos_feed_likes WHERE user_id = '${U4}';")"
	[ "${n}" = "1" ] && return 0
	DETAIL="the like did not land"
	return 1
}

check_9() {
	# Every partition of ai_events lives in the public schema. A relation created
	# without a schema lands in the first schema of the search_path, and the live
	# stack's search_path starts with auth (grobase's 001 sets it on the postgres
	# role) — a partition created without its schema would be invisible to
	# public.ai_events and to the grants.
	elsewhere="$(q "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname <> 'public' AND c.relispartition AND c.relname LIKE 'ai\_events%';")"
	[ "${elsewhere}" = "0" ] || {
		DETAIL="${elsewhere} partition(s) outside the public schema"
		return 1
	}
	run_sql "INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event, ts) VALUES ('${U5}', 'page', '${P1}', '${WS}', 'view', date_trunc('month', now()) - interval '4 months');" || {
		note "the row of a month without a partition failed"
		return 1
	}
	n="$(q "SELECT public.ai_events_default_rows();")"
	if [ -z "${n}" ] || [ "${n}" -le 0 ]; then
		DETAIL="ai_events_default_rows() is ${n:-empty}"
		return 1
	fi
	cur="$(q "SELECT 'ai_events_y' || to_char(date_trunc('month', now()), 'YYYYMM');")"
	next1="$(q "SELECT 'ai_events_y' || to_char(date_trunc('month', now()) + interval '1 month', 'YYYYMM');")"
	next2="$(q "SELECT 'ai_events_y' || to_char(date_trunc('month', now()) + interval '2 month', 'YYYYMM');")"
	old="$(q "SELECT 'ai_events_y' || to_char(date_trunc('month', now()) - interval '8 months', 'YYYYMM');")"
	# The monthly partitions are dropped, so the next maintain() pass has to
	# create them again — and the row in the DEFAULT partition is 4 months old,
	# so it does not block them.
	run_sql "DROP TABLE IF EXISTS public.${cur}, public.${next1}, public.${next2};" || {
		note "the drop of the monthly partitions failed"
		return 1
	}
	cat >"${WORK}/seed.sql" <<SQL
DO \$q\$
DECLARE s date;
BEGIN
    s := (date_trunc('month', now()) - interval '8 months')::date;
    EXECUTE format('CREATE TABLE %I PARTITION OF public.ai_events FOR VALUES FROM (%L) TO (%L)',
                   'ai_events_y' || to_char(s, 'YYYYMM'), s, s + interval '1 month');
END
\$q\$;
SQL
	run_file "${WORK}/seed.sql" || {
		note "the seeded old partition failed"
		return 1
	}
	out="$(q "SELECT public.ai_events_maintain()::text;")"
	missing=0
	for name in "${cur}" "${next1}" "${next2}"; do
		exists="$(q "SELECT to_regclass('public.${name}') IS NOT NULL;")"
		[ "${exists}" = "t" ] || missing=1
		printf '%s' "${out}" | grep -q "${name}" || missing=1
	done
	gone="$(q "SELECT to_regclass('public.${old}') IS NULL;")"
	[ "${missing}" = "0" ] && [ "${gone}" = "t" ] && return 0
	DETAIL="maintain() returned ${out:-nothing}; the old partition is ${gone}"
	return 1
}

check_10() {
	for role in anon authenticated; do
		for tbl in ai_events ai_personalization_settings; do
			if run_sql "SET ROLE ${role}; SELECT count(*) FROM public.${tbl};"; then
				DETAIL="${role} could read ${tbl}"
				return 1
			fi
			grep -q 'permission denied' "${WORK}/sql.err" || {
				DETAIL="${role} on ${tbl}: $(head -1 "${WORK}/sql.err")"
				return 1
			}
		done
	done
	cols="$(q "SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'public.ai_events'::regclass AND attnum > 0 AND NOT attisdropped;")"
	want="id,ts,user_id,item_kind,item_id,workspace_id,event,weight,surface,rec_id,rank,dwell_ms,is_synthetic"
	[ "${cols}" = "${want}" ] && return 0
	DETAIL="the columns are ${cols}"
	return 1
}

check_11() {
	run_sql "INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event) VALUES ('${U5}', 'page', '${P2}', '${WS}', 'view');
INSERT INTO public.ai_personalization_settings (user_id) VALUES ('${U5}') ON CONFLICT (user_id) DO NOTHING;" || {
		note "the rows of the user failed"
		return 1
	}
	own="$(q "SELECT count(*) FROM public.ai_events WHERE user_id = '${U5}';")"
	[ "${own}" = "2" ] || {
		DETAIL="the user holds ${own} row(s), expected 2 (one per partition)"
		return 1
	}
	exported="$(q "SELECT count(*) FROM public.ai_export_user('${U5}');")"
	[ "${exported}" = "${own}" ] || {
		DETAIL="the export holds ${exported} of ${own} rows"
		return 1
	}
	foreign="$(q "SELECT count(*) FROM public.ai_export_user('${U1}') e WHERE e.user_id = '${U5}';")"
	[ "${foreign}" = "0" ] || {
		DETAIL="the export of another user holds ${foreign} of its rows"
		return 1
	}
	before="$(q "SELECT count(*) FROM public.ai_events;")"
	erased="$(q "SELECT public.ai_erase_user('${U5}');")"
	after="$(q "SELECT count(*) FROM public.ai_events;")"
	left="$(q "SELECT count(*) FROM public.ai_events WHERE user_id = '${U5}';")"
	[ "${left}" = "0" ] || {
		DETAIL="${left} row(s) left for the erased user"
		return 1
	}
	# Every partition, not only the parent: the DEFAULT partition is where the
	# row of the old month was.
	in_default="$(q "SELECT count(*) FROM public.ai_events_default WHERE user_id = '${U5}';")"
	[ "${in_default}" = "0" ] || {
		DETAIL="${in_default} row(s) left in the DEFAULT partition"
		return 1
	}
	[ "${erased}" = "${own}" ] || {
		DETAIL="the erase returned ${erased}, expected ${own}"
		return 1
	}
	[ "${after}" = "$((before - erased))" ] || {
		DETAIL="${before} -> ${after} rows: the erasure wrote events of its own"
		return 1
	}
	kept="$(q "SELECT count(*) FROM public.ai_personalization_settings WHERE user_id = '${U5}';")"
	[ "${kept}" = "1" ] || {
		DETAIL="the settings row did not survive the erasure"
		return 1
	}
	return 0
}

check_12() {
	# The runner's glob is "${MODELS_DIR}"/*.sql - it does not reach the
	# models/rollback/ subdirectory.
	picked="$(for f in "${MODELS}"/*.sql; do basename "$f"; done | grep -c 'rollback' || true)"
	[ "${picked}" = "0" ] || {
		DETAIL="the runner's glob picks up ${picked} rollback file(s)"
		return 1
	}
	# The dump has to be a real one, and it has to SEE the capture triggers:
	# otherwise the diff below would be empty for the wrong reason.
	grep -q 'CREATE TABLE public.osionos_feed_likes' "${WORK}/before.dump" || {
		DETAIL="the first dump is empty"
		return 1
	}
	dump_engagement >"${WORK}/with.dump" || {
		note "the dump under the migration failed"
		return 1
	}
	if diff -q "${WORK}/before.dump" "${WORK}/with.dump" >/dev/null 2>&1; then
		DETAIL="the dump does not see the capture triggers - the diff below would be empty for the wrong reason"
		return 1
	fi
	run_file "${ROLLBACK}" || {
		note "the rollback failed"
		return 1
	}
	run_file "${ROLLBACK}" || {
		note "the second rollback failed"
		return 1
	}
	if ! dump_engagement >"${WORK}/after.dump"; then
		note "the second dump failed"
		return 1
	fi
	if ! diff -u "${WORK}/before.dump" "${WORK}/after.dump" >"${WORK}/dump.diff" 2>&1; then
		sed 's/^/  | /' "${WORK}/dump.diff" >&2
		DETAIL="the engagement tables changed under the migration"
		return 1
	fi
	# The migration is applied again: the database is left as the file found it,
	# and the re-apply proves the rollback is a real inverse.
	apply_migration || {
		note "the re-apply after the rollback failed"
		return 1
	}
	return 0
}

# The p95 of 1,000 single-row likes. $1 is the uuid prefix of the users (each
# run needs its own users: the table's key is (page_id, user_id)).
measure_p95() {
	cat >"${WORK}/bench.sql" <<SQL
CREATE TEMP TABLE bench (ms double precision);
DO \$q\$
DECLARE t0 timestamptz; u uuid; i int;
BEGIN
    FOR i IN 1..1000 LOOP
        u := ('$1' || lpad(i::text, 12, '0'))::uuid;
        t0 := clock_timestamp();
        INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES ('${P1}', u);
        INSERT INTO bench VALUES (extract(epoch FROM clock_timestamp() - t0) * 1000.0);
    END LOOP;
END
\$q\$;
SELECT round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ms)::numeric, 4) FROM bench;
SQL
	run_file "${WORK}/bench.sql" || return 1
	tail -1 "${WORK}/sql.out"
}

check_13() {
	with="$(measure_p95 '00000000-0000-4000-8001-')" || {
		note "the measurement with the trigger failed"
		return 1
	}
	run_sql "ALTER TABLE public.osionos_feed_likes DISABLE TRIGGER ai_events_capture_feed_likes;" || {
		note "the trigger could not be disabled"
		return 1
	}
	without="$(measure_p95 '00000000-0000-4000-8002-')" || {
		run_sql "ALTER TABLE public.osionos_feed_likes ENABLE TRIGGER ai_events_capture_feed_likes;" || true
		note "the measurement without the trigger failed"
		return 1
	}
	run_sql "ALTER TABLE public.osionos_feed_likes ENABLE TRIGGER ai_events_capture_feed_likes;" || {
		note "the trigger could not be enabled again"
		return 1
	}
	if [ -z "${with}" ] || [ -z "${without}" ]; then
		DETAIL="no measurement (with ${with:-none}, without ${without:-none})"
		return 1
	fi
	delta="$(awk -v a="${with}" -v b="${without}" 'BEGIN { printf "%.3f", a - b }')"
	DETAIL="p95 ${with} ms with the trigger, ${without} ms without, delta ${delta} ms"
	note "${DETAIL}"
	# The target is +2 ms; only above +10 ms is a failure.
	if awk -v a="${with}" -v b="${without}" 'BEGIN { exit !((a - b) > 10) }'; then
		return 1
	fi
	return 0
}

main() {
	start_pg
	note "postgres up in ${CTN}"
	check_runner_order || {
		note "the runner does not apply the migration after the tables it captures from"
		exit 1
	}
	note "the runner's order is right"
	apply_fixture || {
		note "the fixture failed"
		exit 1
	}
	note "fixture applied (the migration twice)"

	for fn in check_1 check_2 check_3 check_4 check_5 check_6 check_7 check_8 \
		check_9 check_10 check_11 check_12 check_13; do
		DETAIL=""
		if "${fn}"; then
			pass "${fn}" "${DETAIL:-ok}"
		else
			fail "${fn}" "${DETAIL:-failed}"
		fi
	done

	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
