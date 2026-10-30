#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    discussions.sh                                                            #
#                                                                              #
#    Prove suggested edits, replies and reactions                              #
#    (models/osionos-discussions-migration.sql, #228) on a throwaway database. #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES
#   d1  the SQL anchor rules answer the shared fixture exactly as
#       suggestionAnchor.ts does (reanchor, rebase, apply; code points).
#   d2  the CHECKs refuse a malformed row with 23514, never a cast error.
#   d3  accept splices a nested block (children, layout cell), bumps the page
#       version by 1 and answers the full content; reject leaves the page alone.
#   d4  missing / decided / changed / archived / unsupported / stale change nothing.
#   d5  accept supersedes an overlapping suggestion and rebases a later one.
#   d6  S2: a decide whose session dies before commit leaves status and text alone.
#   d7  S3/C14: an edit racing an accept — the applied text is the stored insert,
#       and an accepter who saw the old text gets `changed`.
#   d8  S5: 50 concurrent accepts of overlapping proposals → exactly one accepted,
#       no deadlock; 10 accepts on 10 blocks of one page all land; an accept
#       during a page edit keeps the edit; a reply and a reaction never wait
#       50 ms on a held decide.
#   d9  S4/C13: the delete guard, and page / workspace cascades that pass it.
#   d10 S8: a PATCH of the insert re-queues moderation; a reply or a suggestion
#       adds no 'comment' event.
#   d11 S7: erasing two users who reacted with the same emoji (no 23505), the
#       decider tombstoned.
#   d12 acl: anon / authenticated cannot execute the decide or read reactions.
#   d13 S14: the migration twice is a no-op; the ugc rollback then this rollback
#       (twice) leave a working comments table; a re-apply restores everything.
#
# ISOLATION
#   One throwaway container, ai-disc-pg-$$, with --network none: the live
#   mini-baas-*, track-binocle-* and ai-* containers are never named.
#
# THE FIXTURE
#   The real runner (scripts/apply-models-migrations.sh) over grobase's 001 and
#   012 plus the models-grants shim — the order account-export-lock-race.sh uses,
#   so the file under test is applied at its real alphabetical place.
#
# Usage:  sh scripts/verify/discussions.sh
# Env:    GROBASE_PG_IMAGE (default ghcr.io/univers42/grobase-postgres:latest)
#         GROBASE_SQL      grobase's postgresql migrations directory
#                          (default apps/grobase/scripts/migrations/postgresql)
#         ANCHOR_FIXTURE   the shared fixture (default the osionos submodule's
#                          tests/fixtures/suggestion-anchors.json)
# Exit:   0 every check passed · 1 a check failed · 2 a prerequisite is missing
#
# The checks live in scripts/verify/discussions/ and are SOURCED below; the
# linter reads one file at a time and calls the shared names unused.
# shellcheck disable=SC2034,SC2317,SC2329,SC1091
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_SQL="${GROBASE_SQL:-${REPO}/apps/grobase/scripts/migrations/postgresql}"
ANCHOR_FIXTURE="${ANCHOR_FIXTURE:-${REPO}/apps/osionos/app/tests/fixtures/suggestion-anchors.json}"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
CTN="ai-disc-pg-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/discussions.XXXXXX")"
passed=0
failed=0

note() { printf '[discussions] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

teardown() {
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

# --- psql helpers ------------------------------------------------------------

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
q() { printf '%s\n' "$1" | psql_q; }

apply() {
	if docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <"$1" \
		>"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

# sqlstate_of <sql> — the SQLSTATE the statement fails with, or OK.
sqlstate_of() {
	if printf '\\set VERBOSITY verbose\n%s\n' "$1" | psql_q >"${WORK}/st.out" 2>"${WORK}/st.err"; then
		echo OK
		return 0
	fi
	sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' "${WORK}/st.err" | head -1
}

# check <id> <label> <expected> <actual>
check() {
	if [ "$3" = "$4" ]; then
		printf '  ok   %s %s\n' "$1" "$2"
		return 0
	fi
	printf '  FAIL %s %s: expected %s, got %s\n' "$1" "$2" "$3" "$4"
	return 1
}

# --- fixture -----------------------------------------------------------------

boot() {
	command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 2; }
	[ -f "${GROBASE_SQL}/001_initial_schema.sql" ] || { note "GROBASE_SQL has no 001_initial_schema.sql: ${GROBASE_SQL}"; exit 2; }
	[ -f "${ANCHOR_FIXTURE}" ] || { note "ANCHOR_FIXTURE missing: ${ANCHOR_FIXTURE}"; exit 2; }
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null || { note "${IMAGE} did not start"; exit 2; }
	i=0
	until docker exec "${CTN}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
		i=$((i + 1))
		[ "${i}" -lt 60 ] || { note "pg_isready never answered in 60s"; exit 1; }
		sleep 1
	done
	apply "${DIR}/models-grants/roles.sql" || exit 1
	grep -v '^#' "${GROBASE_SQL}/001_initial_schema.sql" >"${WORK}/001.sql"
	apply "${WORK}/001.sql" || exit 1
	grep -v '^#' "${GROBASE_SQL}/012_realtime_triggers_all_tables.sql" >"${WORK}/012.sql"
	apply "${WORK}/012.sql" || exit 1
	apply "${DIR}/models-grants/shim.sql" || exit 1
	PG_CONTAINER="${CTN}" sh "${RUNNER}" >"${WORK}/runner.log" 2>&1 || {
		note "the runner failed"
		sed 's/^/  | /' "${WORK}/runner.log" >&2
		exit 1
	}
}

U1="11111111-0000-4000-8000-000000000001"
U2="11111111-0000-4000-8000-000000000002"
U3="11111111-0000-4000-8000-000000000003"
WS="22222222-0000-4000-8000-000000000001"

# seed_page <id> <content-json> — a page of the verify workspace.
seed_page() {
	q "INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content, visibility)
	   VALUES ('$1', '${WS}', '${U1}', 'p', \$j\$$2\$j\$::jsonb, 'public')" >/dev/null
}

seed() {
	q "INSERT INTO auth.users (id) VALUES ('${U1}'), ('${U2}'), ('${U3}') ON CONFLICT DO NOTHING;
	   INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${WS}', '${U1}', 'verify', 'verify');" >/dev/null
}

# suggest <id> <page> <block> <start> <end> <quote> <prefix> <suffix> <insert>
suggest() {
	q "INSERT INTO public.osionos_page_comments (id, page_id, block_id, author_id, content, kind, anchor, suggestion)
	   VALUES ('$1', '$2', '$3', '${U2}', '', 'suggestion',
	           jsonb_build_object('start', $4, 'end', $5, 'quote', \$q\$$6\$q\$, 'prefix', \$q\$$7\$q\$, 'suffix', \$q\$$8\$q\$),
	           jsonb_build_object('insert', \$q\$$9\$q\$))" >/dev/null
}

# decide <id> <verdict> [expected updated_at]
decide() {
	stamp=NULL
	[ -z "${3:-}" ] || stamp="'$3'"
	q "SELECT public.osionos_decide_suggestion('$1', '${U1}', '$2', ${stamp})"
}
status_of() { q "SELECT status FROM public.osionos_page_comments WHERE id = '$1'"; }
version_of() { q "SELECT version FROM public.osionos_pages WHERE id = '$1'"; }
block_text() { q "SELECT content #>> (public.osionos_block_path(content, '$2') || ARRAY['content']) FROM public.osionos_pages WHERE id = '$1'"; }

# --- the checks, split by concern --------------------------------------------

# shellcheck source-path=SCRIPTDIR
# shellcheck source=discussions/checks-rules.sh
. "${DIR}/discussions/checks-rules.sh"
# shellcheck source=discussions/checks-decide.sh
. "${DIR}/discussions/checks-decide.sh"
# shellcheck source=discussions/checks-race.sh
. "${DIR}/discussions/checks-race.sh"
# shellcheck source=discussions/checks-lifecycle.sh
. "${DIR}/discussions/checks-lifecycle.sh"

run() {
	if "$2"; then pass "$1" "$3"; else fail "$1" "$3"; fi
}

main() {
	boot
	note "runner applied every model on ${IMAGE}"
	seed
	run d1 check_fixture "the shared anchor fixture"
	run d2 check_constraints "constraints"
	run d3 check_accept_reject "accept and reject"
	run d4 check_refusals "refusals change nothing"
	run d5 check_supersede_rebase "supersede and rebase"
	run d6 check_killed_decide "a killed decide"
	run d7 check_edit_race "edit racing accept"
	run d8 check_concurrent_accepts "50 concurrent accepts"
	run d9 check_delete_and_cascades "delete guard and cascades"
	run d10 check_moderation_events "moderation and events"
	run d11 check_erasure "erasure"
	run d12 check_acl "acl"
	run d13 check_idempotent_and_rollback "idempotent apply and rollback"
	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ]
}

main "$@"
