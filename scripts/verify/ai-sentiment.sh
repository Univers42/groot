#!/bin/sh
# Prove the sentiment queue and store (models/osionos-ugc-sentiment-migration.sql)
# in a throwaway Postgres: --network none, no port, no volume, removed on every
# exit path. Prints one "PASS <name>" or "FAIL <name>" per check.
#
#   a0 the runner applies the migration after ai-jobs and comments (ai_erase_user dispatches dynamically, so the events file may sort either side)
#   a  no settings row -> no sentiment job
#   b  enabling backfills the existing comment, with the right sha
#   c  new comment queued; same-content UPDATE leaves the job alone; a content
#      change re-queues it with the new sha
#   d  osionos.ai_jobs = off -> nothing queued
#   e  disabling deletes the workspace's ai_sentiment rows and jobs (C143)
#   f  deleting a comment deletes its ai_sentiment row (C143)
#   g  ai_erase_user removes the author's rows, keeps the other author's (C143)
#   h  anon and authenticated cannot read ai_sentiment (C145)
#   i  a comment on an archived page is not queued
#   j  moving a database-row projection to a workspace with sentiment disabled
#      deletes the old score and queued job
#
# Caveat: check a0 reads the runner's order from its source with sed, so a
# runner that changes the ORDERED_FIRST/ORDERED_LAST variable names makes a0
# FAIL (loud), never pass silently.
#
# Usage: sh scripts/verify/ai-sentiment.sh [--keep]
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
FIX="${REPO}/scripts/verify/models-grants"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
MIGRATION="osionos-ugc-sentiment-migration.sql"
ROW_MIGRATION="osionos-ugc-sentiment-rows-migration.sql"
CTN="ai-sentiment-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-sentiment.XXXXXX")"
failed=0
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WS_ON=11111111-1111-1111-1111-111111111111
WS_OFF=22222222-2222-2222-2222-222222222222
P_ON=33333333-3333-3333-3333-333333333331
P_OFF=33333333-3333-3333-3333-333333333332
P_ARCH=33333333-3333-3333-3333-333333333333
U1=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
U2=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
SHA64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DB_KEY_MOVE="ai-sentiment-move-db"
R_MOVE=99999999-9999-9999-9999-999999999901

note() { printf '[ai-sentiment] %s\n' "$*" >&2; }
pass() { printf 'PASS %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "${2:-}"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: ${CTN} left up"; return 0; }
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }
run_sql() { printf '%s\n' "$1" | psql_q >"${WORK}/out" 2>"${WORK}/err"; }
q() { printf '%s\n' "$1" | psql_q 2>/dev/null || true; }
sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

apply_file() {
	docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		<"$1" >"${WORK}/apply.log" 2>&1 && return 0
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

start_pg() {
	command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 2; }
	docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 || docker pull "${PG_IMAGE}" >/dev/null 2>&1 || {
		printf 'FAIL image %s\n' "${PG_IMAGE}"
		exit 1
	}
	docker run -d --name "${CTN}" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
		"${PG_IMAGE}" >/dev/null || { note "the container did not start"; exit 1; }
	i=0
	while [ "${i}" -lt 60 ]; do
		docker exec "${CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	note "postgres never became ready"
	exit 1
}

apply_fixture() {
	apply_file "${FIX}/roles.sql" || return 1
	# Pre-1e407614 default privileges: anon/authenticated get everything on new
	# tables, so the migration's own REVOKE is what closes them (check h).
	run_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;" || return 1
	for base in osionos-bridge-migration.sql osionos-chat-migration.sql \
		osionos-social-migration.sql osionos-engagement-migration.sql \
		osionos-comments-migration.sql osionos-favorites-migration.sql \
		osionos-feed-engagement-migration.sql osionos-object-databases-migration.sql \
		osionos-ai-jobs-migration.sql "${MIGRATION}" "${ROW_MIGRATION}" \
		osionos-user-events-migration.sql; do
		apply_file "${MODELS}/${base}" || return 1
	done
	# Twice: idempotence for the base store and database-row projection.
	apply_file "${MODELS}/${MIGRATION}" || return 1
	apply_file "${MODELS}/${ROW_MIGRATION}" || return 1
	run_sql "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
  ('${WS_ON}', '${U1}', 'ws-on', 'ws-on'), ('${WS_OFF}', '${U1}', 'ws-off', 'ws-off');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES
  ('${P_ON}', '${WS_ON}', '${U1}', 'p-on'),
  ('${P_OFF}', '${WS_OFF}', '${U1}', 'p-off'),
  ('${P_ARCH}', '${WS_ON}', '${U1}', 'p-arch');
UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${P_ARCH}';" || return 1
}

# sentiment jobs of a workspace / ai_sentiment rows of a workspace
jobs_of() { q "SELECT count(*) FROM public.ai_jobs WHERE kind = 'sentiment' AND workspace_id = '$1';"; }
rows_of() { q "SELECT count(*) FROM public.ai_sentiment WHERE workspace_id = '$1';"; }
job_sha() { q "SELECT content_sha256 FROM public.ai_jobs WHERE kind = 'sentiment' AND subject_id = '$1';"; }
score() {
	run_sql "INSERT INTO public.ai_sentiment (subject_kind, subject_id, workspace_id, label, confidence, model, content_sha256)
VALUES ('page_comment', '$1', '$2', 'neutral', 0.5, 'm', '${SHA64}');"
}

C1=44444444-4444-4444-4444-444444444401
C2=44444444-4444-4444-4444-444444444402
C3=44444444-4444-4444-4444-444444444403
C4=44444444-4444-4444-4444-444444444404
C5=44444444-4444-4444-4444-444444444405

check_a0() {
	first="$(sed -n 's/^ORDERED_FIRST="\(.*\)"$/\1/p' "${RUNNER}")"
	last="$(sed -n 's/^ORDERED_LAST="\(.*\)"$/\1/p' "${RUNNER}")"
	order="$(for f in "${MODELS}"/*.sql; do
		b="$(basename "$f")"
		case " ${first} ${last} " in *" ${b} "*) continue ;; esac
		printf '%s\n' "${b}"
	done)"
	mine="$(printf '%s\n' "${order}" | grep -n -F "${MIGRATION}" | cut -d: -f1 || true)"
	mine_rows="$(printf '%s\n' "${order}" | grep -n -F "${ROW_MIGRATION}" | cut -d: -f1 || true)"
	[ -n "${mine}" ] && [ -n "${mine_rows}" ] || return 1
	for need in osionos-ai-jobs-migration.sql osionos-comments-migration.sql; do
		at="$(printf '%s\n' "${order}" | grep -n -F "${need}" | cut -d: -f1 || true)"
		[ -z "${at}" ] && at=0
		[ "${at}" -lt "${mine}" ] || { DETAIL="${need} sorts after ${MIGRATION}"; return 1; }
	done
	for need in osionos-object-databases-migration.sql "${MIGRATION}"; do
		at="$(printf '%s\n' "${order}" | grep -n -F "${need}" | cut -d: -f1 || true)"
		[ -n "${at}" ] && [ "${at}" -lt "${mine_rows}" ] || {
			DETAIL="${need} must sort before ${ROW_MIGRATION}"; return 1;
	}
	done
	at="$(printf '%s\n' "${order}" | grep -n -F osionos-user-events-migration.sql | cut -d: -f1 || true)"
	[ -n "${at}" ] && [ "${at}" -gt "${mine_rows}" ] || {
		DETAIL="user-events must sort after ${ROW_MIGRATION}"; return 1;
	}
}

check_a() {
	run_sql "INSERT INTO public.osionos_page_comments (id, page_id, author_id, content) VALUES ('${C1}', '${P_ON}', '${U1}', 'hello one');" || return 1
	[ "$(jobs_of "${WS_ON}")" = "0" ] || { DETAIL="job queued without a settings row"; return 1; }
}

check_b() {
	run_sql "INSERT INTO public.ai_sentiment_settings (workspace_id, enabled) VALUES ('${WS_ON}', true);" || return 1
	[ "$(jobs_of "${WS_ON}")" = "1" ] || { DETAIL="backfill queued $(jobs_of "${WS_ON}") job(s)"; return 1; }
	[ "$(job_sha "${C1}")" = "$(sha_of 'hello one')" ] || { DETAIL="sha differs"; return 1; }
}

check_c() {
	run_sql "INSERT INTO public.osionos_page_comments (id, page_id, author_id, content) VALUES ('${C2}', '${P_ON}', '${U2}', 'hello two');" || return 1
	[ "$(job_sha "${C2}")" = "$(sha_of 'hello two')" ] || { DETAIL="new comment not queued"; return 1; }
	# Mark the job as attempted; a same-content UPDATE must not reset it.
	run_sql "UPDATE public.ai_jobs SET attempts = 3 WHERE subject_id = '${C2}' AND kind = 'sentiment';
UPDATE public.osionos_page_comments SET content = 'hello two', resolved_at = now() WHERE id = '${C2}';" || return 1
	[ "$(q "SELECT attempts FROM public.ai_jobs WHERE subject_id = '${C2}' AND kind = 'sentiment';")" = "3" ] ||
		{ DETAIL="same-content UPDATE reset the job"; return 1; }
	run_sql "UPDATE public.osionos_page_comments SET content = 'changed words' WHERE id = '${C2}';" || return 1
	[ "$(job_sha "${C2}")" = "$(sha_of 'changed words')" ] || { DETAIL="content change did not re-queue"; return 1; }
	[ "$(q "SELECT attempts FROM public.ai_jobs WHERE subject_id = '${C2}' AND kind = 'sentiment';")" = "0" ] ||
		{ DETAIL="re-queue did not reset attempts"; return 1; }
}

check_d() {
	run_sql "BEGIN;
SELECT set_config('osionos.ai_jobs', 'off', true);
INSERT INTO public.osionos_page_comments (id, page_id, author_id, content) VALUES ('${C3}', '${P_ON}', '${U1}', 'silent');
COMMIT;" || return 1
	[ -z "$(job_sha "${C3}")" ] || { DETAIL="job queued with the switch off"; return 1; }
}

check_e() {
	score "${C1}" "${WS_ON}" || return 1
	score "${C2}" "${WS_ON}" || return 1
	[ "$(rows_of "${WS_ON}")" = "2" ] || { DETAIL="setup: scores not stored"; return 1; }
	run_sql "UPDATE public.ai_sentiment_settings SET enabled = false WHERE workspace_id = '${WS_ON}';" || return 1
	[ "$(rows_of "${WS_ON}")" = "0" ] || { DETAIL="$(rows_of "${WS_ON}") ai_sentiment row(s) left"; return 1; }
	[ "$(jobs_of "${WS_ON}")" = "0" ] || { DETAIL="$(jobs_of "${WS_ON}") sentiment job(s) left"; return 1; }
}

check_f() {
	score "${C1}" "${WS_ON}" || return 1
	run_sql "DELETE FROM public.osionos_page_comments WHERE id = '${C1}';" || return 1
	[ "$(q "SELECT count(*) FROM public.ai_sentiment WHERE subject_id = '${C1}';")" = "0" ] ||
		{ DETAIL="score survived its comment"; return 1; }
}

check_g() {
	# C2 is U2's, C4 is U1's; both scored.
	run_sql "INSERT INTO public.osionos_page_comments (id, page_id, author_id, content) VALUES ('${C4}', '${P_ON}', '${U1}', 'u1 words');" || return 1
	score "${C2}" "${WS_ON}" || return 1
	score "${C4}" "${WS_ON}" || return 1
	run_sql "SELECT public.ai_erase_user('${U1}');" || return 1
	[ "$(q "SELECT count(*) FROM public.ai_sentiment WHERE subject_id = '${C4}';")" = "0" ] ||
		{ DETAIL="the erased author's score is still there"; return 1; }
	[ "$(q "SELECT count(*) FROM public.ai_sentiment WHERE subject_id = '${C2}';")" = "1" ] ||
		{ DETAIL="the other author's score was erased"; return 1; }
}

check_h() {
	for role in anon authenticated; do
		if run_sql "SET ROLE ${role}; SELECT count(*) FROM public.ai_sentiment;"; then
			DETAIL="${role} could read ai_sentiment"
			return 1
		fi
		grep -q 'permission denied' "${WORK}/err" || { DETAIL="${role}: $(head -1 "${WORK}/err")"; return 1; }
	done
}

check_i() {
	run_sql "UPDATE public.ai_sentiment_settings SET enabled = true WHERE workspace_id = '${WS_ON}';
INSERT INTO public.osionos_page_comments (id, page_id, author_id, content) VALUES ('${C5}', '${P_ARCH}', '${U2}', 'archived page');" || return 1
	[ -z "$(job_sha "${C5}")" ] || { DETAIL="archived-page comment queued"; return 1; }
}

row_jobs() {
	q "SELECT count(*) FROM public.ai_jobs WHERE kind = 'sentiment' AND subject_kind = 'database_row' AND subject_id = '$1';"
}

row_scores() {
	q "SELECT count(*) FROM public.ai_sentiment WHERE subject_kind = 'database_row' AND subject_id = '$1';"
}

check_j() {
	# WS_ON is opted in; WS_OFF has no settings row (therefore sentiment is off).
	run_sql "INSERT INTO public.osionos_object_databases (owner_id, workspace_id, db_key, title, state)
VALUES ('${U1}', '${WS_ON}', '${DB_KEY_MOVE}', 'move-test', '{}'::jsonb);
INSERT INTO public.osionos_object_database_rows (id, owner_id, db_key, workspace_id, row_id, property_id, scored_text, content_sha256)
VALUES ('${R_MOVE}', '${U1}', '${DB_KEY_MOVE}', '${WS_ON}', 'row-1', 'property-1', 'text to score', '${SHA64}');" || {
		DETAIL="could not create a projected database row: $(head -1 "${WORK}/err")"; return 1;
	}
	[ "$(row_jobs "${R_MOVE}")" = "1" ] || { DETAIL="enabled source workspace did not queue row"; return 1; }
	run_sql "INSERT INTO public.ai_sentiment (subject_kind, subject_id, workspace_id, label, confidence, model, content_sha256)
VALUES ('database_row', '${R_MOVE}', '${WS_ON}', 'neutral', 0.5, 'm', '${SHA64}');" || return 1
	[ "$(row_scores "${R_MOVE}")" = "1" ] || { DETAIL="source score was not stored"; return 1; }
	run_sql "UPDATE public.osionos_object_database_rows SET workspace_id = '${WS_OFF}' WHERE id = '${R_MOVE}';" || {
		DETAIL="workspace move failed: $(head -1 "${WORK}/err")"; return 1;
	}
	[ "$(row_scores "${R_MOVE}")" = "0" ] || { DETAIL="old workspace score survived move to opted-out workspace"; return 1; }
	[ "$(row_jobs "${R_MOVE}")" = "0" ] || { DETAIL="old workspace job survived move to opted-out workspace"; return 1; }
}

main() {
	DETAIL=""
	start_pg
	apply_fixture || { note "the fixture failed"; exit 1; }
	for n in a0 a b c d e f g h i j; do
		DETAIL=""
		if "check_${n}"; then pass "${n}"; else fail "${n}" "${DETAIL}"; fi
	done
	[ "${failed}" -eq 0 ]
}

main "$@"
