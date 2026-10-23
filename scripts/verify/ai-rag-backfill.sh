#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-rag-backfill.sh                                                        #
#                                                                              #
#    Prove that re-applying the RAG migration does not re-queue the pages the  #
#    indexer already drained (groot #109).                                     #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ai-rag-migration.sql, section 7)
#   1  first apply: the queue holds the 3 live pages, not the archived one
#   2  the indexer drains 2 pages (chunks written, queue emptied); a re-apply
#      queues only the 1 page without chunks
#   3  a third apply gives the same queue; the archived page is never queued
#   4  a chunked page queued as an edit (priority 0) keeps its lane on re-apply
#
# THE FIXTURE
#   The dev stack's stand-in (osionos_pages + the page walker + the roles),
#   the pages, models/osionos-ai-migration.sql, then the RAG migration. The
#   pages exist BEFORE the RAG migration, so its section 7 is what queues them.
#   RAG_MIGRATION overrides the migration path (the revert proof points it at
#   a copy without the guard).
#
# ISOLATION
#   One throwaway container: ai-rag-bf-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [RAG_MIGRATION=<file>] sh scripts/verify/ai-rag-backfill.sh
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
# The functions are reached through the loop in main() and the trap, so shellcheck
# cannot see that they are called (SC2329 is the newer name of SC2317; ai-events.sh disables the old one for the same reason).
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
STANDIN="${REPO}/infrastructure/docker/osionos/ai-db-init/00-standin.sql"
RAG="${RAG_MIGRATION:-${MODELS}/osionos-ai-rag-migration.sql}"
CTN="ai-rag-bf-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-rag-backfill.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
P1=22222222-2222-2222-2222-222222222221
P2=22222222-2222-2222-2222-222222222222
P3=22222222-2222-2222-2222-222222222223
PA=22222222-2222-2222-2222-2222222222aa

note() { printf '[ai-rag-backfill] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS: %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s %s\n' "$1" "$2"; }

teardown() {
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }
run_sql() { printf '%s\n' "$1" | psql_q >"${WORK}/sql.out" 2>"${WORK}/sql.err"; }
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

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 || docker pull "${PG_IMAGE}" >/dev/null 2>&1 || {
		printf 'FAIL: image %s\n' "${PG_IMAGE}"
		exit 1
	}
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

apply_rag() { apply_file "${RAG}"; }

# queued — the queue as "page:priority" pairs, sorted, comma-joined.
queued() { q "SELECT coalesce(string_agg(right(page_id::text, 2) || ':' || priority, ',' ORDER BY page_id), '') FROM public.ai_index_queue;"; }

apply_fixture() {
	apply_file "${STANDIN}" || return 1
	# Three live pages and one archived, BEFORE the RAG migration: its section 7
	# is what queues them (no page trigger exists yet).
	run_sql "INSERT INTO public.osionos_pages (id, workspace_id, title, archived_at) VALUES
('${P1}', '${WS}', 'p1', NULL), ('${P2}', '${WS}', 'p2', NULL), ('${P3}', '${WS}', 'p3', NULL),
('${PA}', '${WS}', 'archived', now());" || {
		note "the pages failed"
		return 1
	}
	apply_file "${MODELS}/osionos-ai-migration.sql" || return 1
	apply_rag
}

check_1() {
	got="$(queued)"
	[ "${got}" = "21:1,22:1,23:1" ] && return 0
	DETAIL="queue is '${got}', expected the 3 live pages as 21:1,22:1,23:1"
	return 1
}

# The indexer drains P1 and P2: one chunk each, then the queue is emptied.
check_2() {
	run_sql "INSERT INTO public.ai_chunks (workspace_id, source_kind, source_id, ord, content, content_hash)
SELECT '${WS}', 'page', p, 0, 'text', '\\x00'::bytea FROM unnest(ARRAY['${P1}', '${P2}']::uuid[]) p;
DELETE FROM public.ai_index_queue;" || {
		note "the drain failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	apply_rag || return 1
	got="$(queued)"
	[ "${got}" = "23:1" ] && return 0
	DETAIL="queue is '${got}' after a re-apply, expected only the unchunked page 23:1"
	return 1
}

check_3() {
	apply_rag || return 1
	got="$(queued)"
	arch="$(q "SELECT count(*) FROM public.ai_index_queue WHERE page_id = '${PA}';")"
	[ "${got}" = "23:1" ] && [ "${arch}" = "0" ] && return 0
	DETAIL="queue is '${got}', archived page queued ${arch} time(s)"
	return 1
}

check_4() {
	run_sql "INSERT INTO public.ai_index_queue (page_id, workspace_id, priority) VALUES ('${P1}', '${WS}', 0)
ON CONFLICT (page_id) DO UPDATE SET priority = 0;" || {
		note "the edit-lane row failed"
		return 1
	}
	apply_rag || return 1
	lane="$(q "SELECT priority FROM public.ai_index_queue WHERE page_id = '${P1}';")"
	[ "${lane}" = "0" ] && return 0
	DETAIL="the edit row of a chunked page has priority '${lane}', expected 0"
	return 1
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${RAG}"
	apply_fixture || {
		note "the fixture failed"
		exit 1
	}
	for fn in check_1 check_2 check_3 check_4; do
		DETAIL=""
		if "${fn}"; then
			pass "${fn}" "ok"
		else
			fail "${fn}" "${DETAIL:-failed}"
		fi
	done
	printf 'PASS %s / FAIL %s\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
