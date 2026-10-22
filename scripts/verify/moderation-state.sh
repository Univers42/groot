#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    moderation-state.sh                                                       #
#                                                                              #
#    Prove the moderation state, the append-only audit and the moderation      #
#    queue: the soft state, the refusals, the erasure, the scope of the       #
#    queue and the rollback.                                                   #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ugc-moderation-migration.sql)
#   0  the runner applies the migration after the tables it triggers on
#   1  both comment tables default to 'visible'; 'bogus' is refused with 23514
#   2  the state is exactly reversible: removed -> visible leaves the content
#      byte-identical, and a removed parent comment keeps its replies
#   3  the audit: service_role inserts; UPDATE, DELETE and TRUNCATE are
#      refused; anon and authenticated are refused
#   4  ai_moderation_erase_user erases the authored rows, nulls the actor and
#      leaves the other user's rows; ai_erase_user erases the moderation rows
#      too
#   5  ai_moderation_events_prune deletes a row of 400 days and keeps a recent
#      one, and the erase switch opens the guard for a TRUNCATE too
#   6  the queue is scoped to the public: a public page queues, a private page
#      of a confidential workspace does not, a private page of a public
#      workspace does, an archived page does not, a ghost page id does not
#   7  the queue coalesces: two content edits are one row with the sha of the
#      last edit, and a moderation_state-only update leaves the row untouched
#   8  an edited HELD comment stays held and is re-queued
#   9  the switch (osionos.ai_jobs = 'off') and the failure isolation: a broken
#      queue is a WARNING, the comment still lands
#  10  anon and authenticated cannot read the queue
#  11  the rollback (twice) leaves the two comment tables exactly as they were
#      before the migration
#
# THE FIXTURE
#   The roles of scripts/verify/models-grants/roles.sql, then the PRE-1e407614
#   default privileges (anon and authenticated get everything on every table
#   created from here on) so that the migration's own REVOKE is what closes
#   them — otherwise check 3 and check 10 would pass for the wrong reason.
#   Then the prerequisite models, then the events migration (the erasure of
#   check 4 is ai_erase_user), then the migration itself TWICE.
#
# ISOLATION
#   Throwaway containers only: mod-state-pg, --network none, no port, no
#   volume. The live mini-baas / osionos containers are never touched. The
#   container is removed on every exit path.
#
# Usage:  sh scripts/verify/moderation-state.sh [--keep]
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
MIGRATION="osionos-ugc-moderation-migration.sql"
ROLLBACK="${MODELS}/rollback/osionos-ugc-moderation-rollback.sql"
CTN="mod-state-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/moderation-state.XXXXXX")"
passed=0
failed=0
DETAIL=""
DESCR=""
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# The test data. Two workspaces (one confidential, one public) and four pages,
# so no check can see another's rows.
WS_CONF=11111111-1111-1111-1111-111111111111
WS_PUB=22222222-2222-2222-2222-222222222222
P_PUB=33333333-3333-3333-3333-333333333331
P_PRIV_CONF=33333333-3333-3333-3333-333333333332
P_PRIV_PUB=33333333-3333-3333-3333-333333333333
P_ARCH=33333333-3333-3333-3333-333333333334
GHOST=99999999-9999-9999-9999-999999999999
U1=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
U2=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
U3=cccccccc-cccc-cccc-cccc-cccccccccccc
U4=dddddddd-dddd-dddd-dddd-dddddddddddd
U5=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee

note() { printf '[moderation-state] %s\n' "$*" >&2; }
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

# sha_of <text> — the sha256 of the text, the way the trigger computes it:
# encode(sha256(convert_to(content,'UTF8')),'hex'). Computed OUTSIDE the
# database, so the check does not compare the database with itself.
sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

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

# The schema of the two comment tables — the ones the migration touches. The
# \restrict token is random per dump (pg_dump 16.10+), so it is filtered out:
# it is not a schema difference.
dump_comments() {
	docker exec "${CTN}" pg_dump -U postgres -d postgres --schema-only \
		-t 'public.osionos_feed_comments' \
		-t 'public.osionos_page_comments' >"${WORK}/raw.dump" 2>"${WORK}/dump.err" || return 1
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

# The migration triggers on tables other files create, and JOINs tables other
# files create. The alphabetical pass is the only slot both runners share, so
# the file is NAMED to sort after them (see the migration's header). This reads
# the runner's order instead of trusting the name: a file that moved would
# break the enqueue on a fresh database, and only the order says so.
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
			note "${need} is applied after ${MIGRATION} — the enqueue would fail on a fresh database"
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
	# REVOKE has to close them, or checks 3 and 10 would pass for the wrong
	# reason.
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
	# The events migration: check 4 erases through ai_erase_user, and its
	# capture triggers sit on the same two comment tables the rollback has to
	# leave alone.
	apply_file "${MODELS}/osionos-user-events-migration.sql" || {
		note "the fixture could not apply the events migration"
		return 1
	}
	# The schema of the comment tables, BEFORE the migration touched them.
	dump_comments >"${WORK}/before.dump" || {
		note "the first dump failed"
		return 1
	}
	# The migration, twice.
	apply_migration || return 1
	apply_migration || return 1
	# The test data: two workspaces, four pages.
	run_sql "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
  ('${WS_CONF}', '${U1}', 'ws-conf', 'ws-conf'),
  ('${WS_PUB}', '${U1}', 'ws-pub', 'ws-pub');
UPDATE public.osionos_workspaces SET visibility = 'confidential' WHERE id = '${WS_CONF}';
UPDATE public.osionos_workspaces SET visibility = 'public' WHERE id = '${WS_PUB}';
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, visibility) VALUES
  ('${P_PUB}', '${WS_CONF}', '${U1}', 'p-public', 'public'),
  ('${P_PRIV_CONF}', '${WS_CONF}', '${U1}', 'p-private-conf', 'private'),
  ('${P_PRIV_PUB}', '${WS_PUB}', '${U1}', 'p-private-pub', 'private'),
  ('${P_ARCH}', '${WS_PUB}', '${U1}', 'p-archived', 'public');
UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${P_ARCH}';" || {
		note "the test data failed"
		return 1
	}
	return 0
}

# --- the checks ------------------------------------------------------------

# 0 — the runner's order.
check_0() {
	if check_runner_order; then
		DESCR="the runner applies the migration after the tables it triggers on"
		return 0
	fi
	DETAIL="the runner does not apply the migration after the tables it needs"
	return 1
}

# 1 — the soft state: the default, the CHECK, the columns, the index.
check_1() {
	for t in osionos_feed_comments osionos_page_comments; do
		cols="$(q "SELECT count(*) FROM information_schema.columns WHERE table_name = '${t}' AND column_name IN ('moderation_state','moderation_changed_at');")"
		[ "${cols}" = "2" ] || {
			DETAIL="${t} has ${cols} moderation column(s), expected 2"
			return 1
		}
		def="$(q "SELECT column_default FROM information_schema.columns WHERE table_name = '${t}' AND column_name = 'moderation_state';")"
		[ "${def}" = "'visible'::text" ] || {
			DETAIL="${t}.moderation_state defaults to ${def:-nothing}"
			return 1
		}
		idx="$(q "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = '${t}_moderation_state_idx';")"
		[ "${idx}" = "1" ] || {
			DETAIL="${t} has ${idx} partial moderation index(es), expected 1"
			return 1
		}
		partial="$(q "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = '${t}_moderation_state_idx' AND i.indpred IS NOT NULL;")"
		[ "${partial}" = "1" ] || {
			DETAIL="${t}_moderation_state_idx is not a partial index"
			return 1
		}
		st="$(state_of "INSERT INTO public.${t} (page_id, author_id, content, moderation_state) VALUES ('${P_PUB}', '${U1}', 'bogus state', 'bogus');")"
		[ "${st}" = "23514" ] || {
			DETAIL="${t} refused 'bogus' with ${st:-no error}, expected 23514"
			return 1
		}
		n="$(q "SELECT count(*) FROM public.${t} WHERE moderation_state <> 'visible';")"
		[ "${n}" = "0" ] || {
			DETAIL="${t} has ${n} row(s) that are not 'visible' by default"
			return 1
		}
	done
	DESCR="both comment tables default to 'visible' and refuse 'bogus' with 23514"
	return 0
}

# 2 — the state is exactly reversible, and never a delete.
check_2() {
	cid=44444444-4444-4444-4444-444444444401
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('${cid}', '${P_PUB}', '${U1}', 'the original words');" || {
		note "the comment failed"
		return 1
	}
	before="$(q "SELECT md5(content) FROM public.osionos_feed_comments WHERE id = '${cid}';")"
	run_sql "UPDATE public.osionos_feed_comments SET moderation_state = 'removed' WHERE id = '${cid}';" || {
		note "the removal failed"
		return 1
	}
	state="$(q "SELECT moderation_state FROM public.osionos_feed_comments WHERE id = '${cid}';")"
	[ "${state}" = "removed" ] || {
		DETAIL="the state is ${state:-nothing}, expected removed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET moderation_state = 'visible' WHERE id = '${cid}';" || {
		note "the restore failed"
		return 1
	}
	after="$(q "SELECT md5(content) FROM public.osionos_feed_comments WHERE id = '${cid}';")"
	if [ "${before}" != "${after}" ] || [ -z "${after}" ]; then
		DETAIL="the content changed: md5 ${before:-none} -> ${after:-none}"
		return 1
	fi
	# A removed parent comment keeps its replies: moderation never deletes.
	parent=44444444-4444-4444-4444-444444444402
	reply=44444444-4444-4444-4444-444444444403
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('${parent}', '${P_PUB}', '${U1}', 'the parent');
INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content, parent_id) VALUES ('${reply}', '${P_PUB}', '${U2}', 'the reply', '${parent}');" || {
		note "the parent or the reply failed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET moderation_state = 'removed' WHERE id = '${parent}';" || {
		note "the removal of the parent failed"
		return 1
	}
	left="$(q "SELECT count(*) FROM public.osionos_feed_comments WHERE id = '${reply}';")"
	[ "${left}" = "1" ] || {
		DETAIL="the reply of a removed parent is gone (${left} row(s) left)"
		return 1
	}
	DESCR="the state is exactly reversible and a removed parent keeps its replies"
	return 0
}

# 3 — the audit: append-only, and service_role only.
check_3() {
	run_sql "SET ROLE service_role;
INSERT INTO public.ai_moderation_events (subject_kind, subject_id, author_id, layer, action, mode, content_sha256, reason) VALUES ('feed_comment', 'audit-1', '${U5}', 'l1', 'hold', 'on', '$(sha_of 'audit-1')', 'spam');" || {
		note "the service_role insert was refused"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE subject_id = 'audit-1';")"
	[ "${n}" = "1" ] || {
		DETAIL="${n} row(s) for the audit insert, expected 1"
		return 1
	}
	# The refusals: as service_role, which holds the privilege. It is the
	# trigger that refuses, not the grant.
	for stmt in \
		"UPDATE public.ai_moderation_events SET action = 'allow';" \
		"DELETE FROM public.ai_moderation_events;" \
		"TRUNCATE public.ai_moderation_events;"; do
		run_sql "SET ROLE service_role; ${stmt}" && {
			DETAIL="service_role could ${stmt}"
			return 1
		}
		grep -q 'append-only' "${WORK}/sql.err" || {
			DETAIL="service_role ${stmt}: $(head -1 "${WORK}/sql.err")"
			return 1
		}
	done
	left="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE subject_id = 'audit-1';")"
	[ "${left}" = "1" ] || {
		DETAIL="the audit row did not survive the refusals (${left} left)"
		return 1
	}
	for role in anon authenticated; do
		if run_sql "SET ROLE ${role}; SELECT count(*) FROM public.ai_moderation_events;"; then
			DETAIL="${role} could read ai_moderation_events"
			return 1
		fi
		grep -q 'permission denied' "${WORK}/sql.err" || {
			DETAIL="${role} on ai_moderation_events: $(head -1 "${WORK}/sql.err")"
			return 1
		}
	done
	DESCR="the audit is append-only and readable by service_role only"
	return 0
}

# 4 — the erasure: the authored rows go, the actor loses the name, the other
#     user's rows stay.
check_4() {
	run_sql "INSERT INTO public.ai_moderation_events (subject_kind, subject_id, author_id, layer, action, actor_id) VALUES
  ('feed_comment', 'own-1', '${U1}', 'l1', 'hold', NULL),
  ('feed_comment', 'own-2', '${U1}', 'l2', 'remove', NULL),
  ('feed_comment', 'act-1', '${U2}', 'admin', 'remove', '${U1}'),
  ('feed_comment', 'other-1', '${U2}', 'l1', 'allow', NULL);" || {
		note "the audit rows failed"
		return 1
	}
	erased="$(q "SELECT public.ai_moderation_erase_user('${U1}');")"
	[ "${erased}" = "2" ] || {
		DETAIL="the erase returned ${erased:-nothing}, expected 2"
		return 1
	}
	own="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE author_id = '${U1}';")"
	[ "${own}" = "0" ] || {
		DETAIL="${own} authored row(s) left for the erased user"
		return 1
	}
	other="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE author_id = '${U2}';")"
	[ "${other}" = "2" ] || {
		DETAIL="${other} row(s) left for the other user, expected 2"
		return 1
	}
	# An admin's erasure keeps the decision, not the name.
	kept="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE subject_id = 'act-1' AND actor_id IS NULL;")"
	[ "${kept}" = "1" ] || {
		DETAIL="the decision of the erased admin did not survive with a NULL actor"
		return 1
	}
	# ai_erase_user (the events file) erases the moderation rows too.
	run_sql "INSERT INTO public.ai_moderation_events (subject_kind, subject_id, author_id, layer, action) VALUES ('feed_comment', 'own-3', '${U3}', 'l1', 'hold');" || {
		note "the audit row of the third user failed"
		return 1
	}
	run_sql "SELECT public.ai_erase_user('${U3}');" || {
		note "ai_erase_user failed"
		return 1
	}
	cleared="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE author_id = '${U3}';")"
	[ "${cleared}" = "0" ] || {
		DETAIL="${cleared} moderation row(s) left after ai_erase_user"
		return 1
	}
	# The switch must not outlive the erasure: a later UPDATE in the SAME
	# transaction is still refused.
	run_sql "BEGIN; SELECT public.ai_moderation_erase_user('${U3}'); UPDATE public.ai_moderation_events SET action = 'allow'; COMMIT;" && {
		DETAIL="an UPDATE after ai_moderation_erase_user in the same transaction got through"
		return 1
	}
	grep -q 'append-only' "${WORK}/sql.err" || {
		DETAIL="same-transaction UPDATE: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	DESCR="the erasure clears the authored rows, nulls the actor, keeps the other's"
	return 0
}

# 5 — the prune: the retention.
check_5() {
	run_sql "INSERT INTO public.ai_moderation_events (subject_kind, subject_id, author_id, layer, action, ts) VALUES
  ('feed_comment', 'old-1', '${U4}', 'l1', 'hold', now() - interval '400 days'),
  ('feed_comment', 'new-1', '${U4}', 'l1', 'hold', now() - interval '10 days');" || {
		note "the audit rows failed"
		return 1
	}
	cut="$(q "SELECT public.ai_moderation_events_prune();")"
	[ "${cut}" = "1" ] || {
		DETAIL="the prune deleted ${cut:-nothing} row(s), expected 1"
		return 1
	}
	gone="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE subject_id = 'old-1';")"
	[ "${gone}" = "0" ] || {
		DETAIL="the row of 400 days survived the prune"
		return 1
	}
	kept="$(q "SELECT count(*) FROM public.ai_moderation_events WHERE subject_id = 'new-1';")"
	[ "${kept}" = "1" ] || {
		DETAIL="the recent row did not survive the prune"
		return 1
	}
	# The switch is a switch: the same guard that refused the TRUNCATE of
	# check 3 lets it through when the erasure asked for it.
	run_sql "BEGIN; SET LOCAL osionos.moderation_erase = 'on'; TRUNCATE public.ai_moderation_events; COMMIT;" || {
		note "the truncate with the erase switch on failed"
		return 1
	}
	left="$(q "SELECT count(*) FROM public.ai_moderation_events;")"
	[ "${left}" = "0" ] || {
		DETAIL="${left} row(s) left after the truncate with the switch on"
		return 1
	}
	DESCR="the prune deletes a row of 400 days, keeps a recent one, and the switch opens the guard"
	return 0
}

# 6 — the scope of the queue: the public content only.
check_6() {
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES
  ('44444444-4444-4444-4444-444444444411', '${P_PUB}', '${U1}', 'on a public page'),
  ('44444444-4444-4444-4444-444444444412', '${P_PRIV_CONF}', '${U1}', 'on a private page of a confidential workspace'),
  ('44444444-4444-4444-4444-444444444413', '${P_PRIV_PUB}', '${U1}', 'on a private page of a public workspace'),
  ('44444444-4444-4444-4444-444444444414', '${P_ARCH}', '${U1}', 'on an archived page');" || {
		note "the comments failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_kind = 'feed_comment' AND subject_id = '44444444-4444-4444-4444-444444444411';")"
	[ "${n}" = "1" ] || {
		DETAIL="a comment on a public page queued ${n} job(s), expected 1"
		return 1
	}
	sha="$(q "SELECT content_sha256 FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444411';")"
	[ "${sha}" = "$(sha_of 'on a public page')" ] || {
		DETAIL="the sha of the job is ${sha:-none}, expected $(sha_of 'on a public page')"
		return 1
	}
	ws="$(q "SELECT workspace_id FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444411';")"
	[ "${ws}" = "${WS_CONF}" ] || {
		DETAIL="the job holds the workspace ${ws:-none}, expected ${WS_CONF}"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444412';")"
	[ "${n}" = "0" ] || {
		DETAIL="a private page of a confidential workspace queued ${n} job(s), expected 0"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444413';")"
	[ "${n}" = "1" ] || {
		DETAIL="a private page of a public workspace queued ${n} job(s), expected 1"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444414';")"
	[ "${n}" = "0" ] || {
		DETAIL="an archived page queued ${n} job(s), expected 0"
		return 1
	}
	# A ghost page id: the comment lands, the queue skips it.
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('44444444-4444-4444-4444-444444444415', '${GHOST}', '${U1}', 'on a ghost page');" || {
		note "the comment on a ghost page id failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '44444444-4444-4444-4444-444444444415';")"
	[ "${n}" = "0" ] || {
		DETAIL="a ghost page id queued ${n} job(s), expected 0"
		return 1
	}
	DESCR="the queue takes the public content only"
	return 0
}

# 7 — the queue coalesces: one row per subject and kind.
check_7() {
	cid=44444444-4444-4444-4444-444444444421
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('${cid}', '${P_PUB}', '${U1}', 'first version');" || {
		note "the comment failed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET content = 'second version' WHERE id = '${cid}';" || {
		note "the first edit failed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET content = 'third version' WHERE id = '${cid}';" || {
		note "the second edit failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	[ "${n}" = "1" ] || {
		DETAIL="${n} job row(s) for two edits of one comment, expected 1"
		return 1
	}
	sha="$(q "SELECT content_sha256 FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	[ "${sha}" = "$(sha_of 'third version')" ] || {
		DETAIL="the job holds the sha of another version: ${sha:-none}"
		return 1
	}
	# A moderation_state-only update touches the queue not at all.
	before="$(q "SELECT enqueued_at FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	run_sql "UPDATE public.osionos_feed_comments SET moderation_state = 'held' WHERE id = '${cid}';" || {
		note "the moderation_state update failed"
		return 1
	}
	after="$(q "SELECT enqueued_at FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	if [ "${before}" != "${after}" ] || [ -z "${before}" ]; then
		DETAIL="a moderation_state-only update re-queued the subject: ${before:-none} -> ${after:-none}"
		return 1
	fi
	DESCR="the queue coalesces the edits and ignores a moderation_state update"
	return 0
}

# 8 — an edited HELD comment stays held and is re-queued.
check_8() {
	cid=44444444-4444-4444-4444-444444444431
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('${cid}', '${P_PUB}', '${U1}', 'held version');" || {
		note "the comment failed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET moderation_state = 'held' WHERE id = '${cid}';" || {
		note "the hold failed"
		return 1
	}
	run_sql "UPDATE public.osionos_feed_comments SET content = 'held version, edited' WHERE id = '${cid}';" || {
		note "the edit failed"
		return 1
	}
	state="$(q "SELECT moderation_state FROM public.osionos_feed_comments WHERE id = '${cid}';")"
	[ "${state}" = "held" ] || {
		DETAIL="the edited comment is ${state:-nothing}, expected held"
		return 1
	}
	sha="$(q "SELECT content_sha256 FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	[ "${sha}" = "$(sha_of 'held version, edited')" ] || {
		DETAIL="the held comment was not re-queued with the new sha: ${sha:-none}"
		return 1
	}
	DESCR="an edited held comment stays held and is re-queued"
	return 0
}

# 9 — the switch and the failure isolation.
check_9() {
	cid=44444444-4444-4444-4444-444444444441
	run_sql "BEGIN; SET LOCAL osionos.ai_jobs = 'off'; INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('${cid}', '${P_PUB}', '${U1}', 'with the queue off'); COMMIT;" || {
		note "the comment with the queue off failed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.ai_jobs WHERE subject_id = '${cid}';")"
	[ "${n}" = "0" ] || {
		DETAIL="${n} job(s) with the queue off"
		return 1
	}
	# A broken queue is a warning, never a failed comment.
	run_sql "ALTER TABLE public.ai_jobs RENAME TO ai_jobs_moved;" || {
		note "the rename failed"
		return 1
	}
	landed=0
	run_sql "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content) VALUES ('44444444-4444-4444-4444-444444444442', '${P_PUB}', '${U1}', 'with a broken queue');" && landed=1
	warned=0
	grep -q 'ai_jobs enqueue skipped' "${WORK}/sql.err" && warned=1
	run_sql "ALTER TABLE public.ai_jobs_moved RENAME TO ai_jobs;" || {
		note "the rename back failed"
		return 1
	}
	[ "${landed}" = "1" ] || {
		DETAIL="the comment failed while the queue was broken"
		return 1
	}
	[ "${warned}" = "1" ] || {
		DETAIL="the queue failed silently — no warning was printed"
		return 1
	}
	n="$(q "SELECT count(*) FROM public.osionos_feed_comments WHERE id = '44444444-4444-4444-4444-444444444442';")"
	[ "${n}" = "1" ] || {
		DETAIL="the comment did not land while the queue was broken"
		return 1
	}
	DESCR="the switch stops the queue and a broken queue is only a warning"
	return 0
}

# 10 — the queue is service_role only.
check_10() {
	for role in anon authenticated; do
		if run_sql "SET ROLE ${role}; SELECT count(*) FROM public.ai_jobs;"; then
			DETAIL="${role} could read ai_jobs"
			return 1
		fi
		grep -q 'permission denied' "${WORK}/sql.err" || {
			DETAIL="${role} on ai_jobs: $(head -1 "${WORK}/sql.err")"
			return 1
		}
	done
	DESCR="anon and authenticated cannot read the queue"
	return 0
}

# 11 — the rollback: the two comment tables are exactly as they were.
check_11() {
	# The runner's glob is "${MODELS_DIR}"/*.sql - it does not reach the
	# models/rollback/ subdirectory.
	picked="$(for f in "${MODELS}"/*.sql; do basename "$f"; done | grep -c 'rollback' || true)"
	[ "${picked}" = "0" ] || {
		DETAIL="the runner's glob picks up ${picked} rollback file(s)"
		return 1
	}
	# The dump has to be a real one, and it has to SEE the enqueue triggers:
	# otherwise the diff below would be empty for the wrong reason.
	grep -q 'CREATE TABLE public.osionos_feed_comments' "${WORK}/before.dump" || {
		DETAIL="the first dump is empty"
		return 1
	}
	dump_comments >"${WORK}/with.dump" || {
		note "the dump under the migration failed"
		return 1
	}
	if diff -q "${WORK}/before.dump" "${WORK}/with.dump" >/dev/null 2>&1; then
		DETAIL="the dump does not see the enqueue triggers - the diff below would be empty for the wrong reason"
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
	if ! dump_comments >"${WORK}/after.dump"; then
		note "the second dump failed"
		return 1
	fi
	if ! diff -u "${WORK}/before.dump" "${WORK}/after.dump" >"${WORK}/dump.diff" 2>&1; then
		sed 's/^/  | /' "${WORK}/dump.diff" >&2
		DETAIL="the comment tables changed under the migration"
		return 1
	fi
	# The migration is applied again: the database is left as the file found
	# it, and the re-apply proves the rollback is a real inverse.
	apply_migration || {
		note "the re-apply after the rollback failed"
		return 1
	}
	DESCR="the rollback (twice) leaves the comment tables as they were"
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

	for fn in check_0 check_1 check_2 check_3 check_4 check_5 check_6 check_7 \
		check_8 check_9 check_10 check_11; do
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
