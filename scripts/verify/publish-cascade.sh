#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    publish-cascade.sh                                                        #
#                                                                              #
#    Prove published snapshots die with the hold on their page                 #
#    (models/osionos-publish-migration.sql, the C633 cascade block)            #
#    on a throwaway database.                                                  #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES (devil verdict share-p1, C633: a page published to the
#   anonymous web must stop being served the moment its owner no longer holds
#   it)
#   c1  archiving a published page removes its snapshot row; a content, title
#       or icon update of another published page leaves the row AND its
#       published_at untouched.
#   c2  changing the page's owner removes the snapshot row (the erase's
#       transfer of a shared page included).
#   c3  changing the page's workspace removes the snapshot row.
#   c4  deleting the owner's osionos_workspace_members row removes ONLY that
#       owner's published pages in THAT workspace; an other member's page
#       stays, the same owner's page in another workspace stays, and a role
#       change (editor -> viewer) removes nothing.
#   c5  deleting the workspace removes its published rows (the existing ON
#       DELETE CASCADE, pinned).
#   c6  erasing the owner (public.osionos_account_erase) removes their
#       published rows. The erasure stage's own fixtures are applied for real:
#       a failure there is a FAIL with the psql error, never a silent skip.
#   c7  re-running the whole publish migration is a no-op: one trigger of each
#       name, no drift in columns, functions, index, ACL or rows.
#   c8  anon and authenticated cannot EXECUTE either trigger function.
#   c9  the revert proof: drop the osionos_pages trigger and c1's archive
#       FAILS (the row survives), then re-apply and the check passes again.
#   c10 the hot path: the trigger's cost on a single-row content UPDATE is
#       measured (median of 7 runs of 5,000 UPDATEs, with the trigger and
#       without) and must stay under a 1.10x ratio.
#   c11 re-keying a members row (UPDATE of user_id or workspace_id) removes
#       the old holder's snapshots; a bystander's stays.
#   c12 re-applying the publish migration backfills: an archived page, an
#       owner with no members row and an owner mismatch lose their snapshot; a
#       marketplace page (no members row by design) and a consistent row stay.
#   c13 staging a workspace delete (pending_delete_at) removes that
#       workspace's snapshots only; a workspace already pending when the hold
#       file first runs is cleaned by its backfill.
#
# ISOLATION
#   Throwaway containers only, on a network this script creates and removes:
#   ai-pc-net and ai-pc-pg (pgvector/pgvector:0.8.0-pg16). The live
#   mini-baas-*, track-binocle-*, ai-dev-*, ai-eval-* and ai-gpu-* containers
#   are never read, written or stopped: this script only ever names the
#   ai-pc-* ones.
#
# THE FIXTURE
#   scripts/verify/page-version.sh and membership-cutoff.sh reuses roles.sql
#   from scripts/verify/models-grants/ and stands auth.users in with its own
#   shim; this script does the same, then applies the runner's ORDERED_FIRST
#   models (bridge, chat, social, engagement), the file under test, and the
#   service-role-only sweep the runner applies last. No apps/grobase
#   submodule, no live stack.
#
# Usage:  sh scripts/verify/publish-cascade.sh [--keep]
#           --keep   leave the container and the network up afterwards
#
# Env:    PG_IMAGE   (default pgvector/pgvector:0.8.0-pg16)
#
# Exit:   0 every check passed · 1 a check failed · 2 docker is missing
#
# Ponytail: two AFTER triggers plus their WHEN clauses are the whole subject;
#   nothing else of the model layer is exercised here.
#
# The checks live in scripts/verify/publish-cascade/ and are SOURCED below, not
# inlined. The linter reads one file at a time, so it cannot see that the page
# ids, the users and the helpers set here are used by the check files, nor that
# the helpers here are called by them: it calls them unused, unreachable or
# unfollowable. Those three codes are off in this file for that reason alone.
# shellcheck disable=SC2034,SC2317,SC2329,SC1091
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
PUBLISH_SQL="${MODELS}/osionos-publish-migration.sql"
LIFECYCLE_SQL="${MODELS}/osionos-workspace-lifecycle-migration.sql"
HOLD_SQL="${MODELS}/osionos-workspace-publish-hold-migration.sql"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
NET="ai-pc-net"
# An explicit subnet: the 172.16-172.31 default pool is full on this machine (31
# other networks live there), and this script must not touch any of them.
PC_SUBNET="${PC_SUBNET:-10.88.11.0/24}"
PG_CTN="ai-pc-pg"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-cascade.XXXXXX")"
passed=0
failed=0

note() { printf '[publish-cascade] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: ${PG_CTN} / ${NET} left up"; return 0; }
	docker rm -f "${PG_CTN}" >/dev/null 2>&1 || true
	docker network rm "${NET}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

# --- psql helpers ------------------------------------------------------------

# psql in the throwaway container; -qAt = quiet, unaligned, tuples only.
psql_q() {
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt
}

# q <sql> — run one statement, print its rows.
q() {
	printf '%s\n' "$1" | psql_q
}

# qf <file> — run a file, print its rows.
qf() {
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"$1"
}

# apply <file> — psql a file with ON_ERROR_STOP; the stderr is echoed on failure.
apply() {
	if docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <"$1" \
		>"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

# publish_pub <page_id> — 1 while the page still holds a published snapshot.
pub_row() {
	q "SELECT count(*) FROM public.osionos_published_pages WHERE page_id = '$1'"
}

# published_at <page_id> — the snapshot's published_at, for the untouched check.
published_at() {
	q "SELECT coalesce(published_at::text, '-') FROM public.osionos_published_pages WHERE page_id = '$1'"
}

# undo_stream — every check that breaks the trigger restores the migration file,
# which is the source of truth (the identical shape page-version's c9 uses).
undo_stream() {
	apply "${PUBLISH_SQL}"
}

# --- fixture -----------------------------------------------------------------

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"; exit 2
	}
	docker network create --subnet "${PC_SUBNET}" "${NET}" >/dev/null
	docker run -d --name "${PG_CTN}" --network "${NET}" \
		-e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
	i=0
	while [ "${i}" -lt 60 ]; do
		if docker exec "${PG_CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	note "postgres never became ready"
	exit 1
}

# The stand-ins the shim models-grants/shim.sql provides on a real stack, plus
# the public.users shape account-profiles needs (its backfill and its directory
# view read u.created_at, u.updated_at, u.name, u.username and up.display_name,
# up.avatar_url, up.id). applications/grobase 001 provides those live; no
# submodule is needed here.
apply_fixture() {
	apply "${FIX}/roles.sql" || exit 1
	printf '%s\n' \
		'CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb);' \
		'CREATE TABLE IF NOT EXISTS public.users (id uuid PRIMARY KEY, email text, username text, name text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());' \
		'CREATE TABLE IF NOT EXISTS public.user_profiles (id serial, user_id uuid NOT NULL UNIQUE, display_name text, avatar_url text);' \
		| docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q >/dev/null
	# The runner's ORDERED_FIRST, in the runner's order: each is a cross-file
	# dependency (chat -> engagement's osionos_notifications, which c6's
	# promotion branch inserts into; chat/profile -> account-profiles' backfill).
	for base in \
		osionos-bridge-migration.sql \
		osionos-chat-migration.sql \
		osionos-social-migration.sql \
		osionos-engagement-migration.sql; do
		apply "${MODELS}/${base}" || exit 1
	done
	apply "${PUBLISH_SQL}" || exit 1
	# The alphabetical pass: lifecycle adds pending_delete_at, the hold reads it.
	apply "${LIFECYCLE_SQL}" || exit 1
	apply "${HOLD_SQL}" || exit 1
	# The sweep the runner runs LAST (ORDERED_LAST): nothing anon or
	# authenticated holds after it.
	apply "${MODELS}/osionos-service-role-only-migration.sql" || exit 1
}

# The six actors. A publishes and loses the hold four ways (c1-c4); B is the
# other member; E is erased in c6; K is the member the erase promotes.
A="22222222-0000-4000-8000-00000000000a"
B="22222222-0000-4000-8000-00000000000b"
E="22222222-0000-4000-8000-00000000000e"
K="22222222-0000-4000-8000-00000000000d"
W="11111111-0000-4000-8000-000000000001"
V="11111111-0000-4000-8000-000000000002"
MD="11111111-0000-4000-8000-000000000003"
EWS="11111111-0000-4000-8000-000000000004"

# The pages. PA1 archives (c1), PA2 is updated (c1 negative), PA3 changes
# owner (c2), PA4 moves (c3), PBW/PBV are the stays (c4), PMD1/PMD2 die with
# the workspace (c5) and PKMD pins the workspace cascade itself (its owner K
# holds no members row in MD, so only the table's ON DELETE CASCADE can remove
# its snapshot), PEV1/PEV2/PKW belong to the erasure (c6), PC9 serves the
# revert proof (c9) and PBM the benchmark (c10).
PA1="aaaaaaaa-0000-4000-8000-000000000001"
PA2="aaaaaaaa-0000-4000-8000-000000000002"
PA3="aaaaaaaa-0000-4000-8000-000000000003"
PA4="aaaaaaaa-0000-4000-8000-000000000004"
PBW="aaaaaaaa-0000-4000-8000-000000000005"
PBV="aaaaaaaa-0000-4000-8000-000000000006"
PMD1="aaaaaaaa-0000-4000-8000-000000000007"
PMD2="aaaaaaaa-0000-4000-8000-000000000008"
PEV1="aaaaaaaa-0000-4000-8000-000000000009"
PEV2="aaaaaaaa-0000-4000-8000-000000000010"
PKW="aaaaaaaa-0000-4000-8000-000000000011"
PC9="aaaaaaaa-0000-4000-8000-000000000012"
PBM="aaaaaaaa-0000-4000-8000-000000000013"
PKMD="aaaaaaaa-0000-4000-8000-000000000014"

seed() {
	q "
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
VALUES ('${W}', '${B}', 'w-shared', 'w-shared-${W}'),
       ('${V}', '${B}', 'w-move', 'w-move-${V}'),
       ('${MD}', '${B}', 'w-doomed', 'w-doomed-${MD}'),
       ('${EWS}', '${E}', 'w-erase', 'w-erase-${EWS}');
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role) VALUES
 ('${W}', '${B}', 'owner'), ('${W}', '${A}', 'editor'), ('${W}', '${E}', 'editor'),
 ('${V}', '${B}', 'owner'), ('${V}', '${A}', 'editor'),
 ('${MD}', '${B}', 'owner'), ('${MD}', '${A}', 'editor'),
 ('${EWS}', '${E}', 'owner'), ('${EWS}', '${K}', 'admin');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content, visibility) VALUES
 ('${PA1}', '${W}', '${A}', 'archive-me', '[]'::jsonb, 'public'),
 ('${PA2}', '${W}', '${A}', 'update-me', '[]'::jsonb, 'public'),
 ('${PA3}', '${W}', '${A}', 'reassign-me', '[]'::jsonb, 'public'),
 ('${PA4}', '${W}', '${A}', 'move-me', '[]'::jsonb, 'public'),
 ('${PBW}', '${W}', '${B}', 'stays-w', '[]'::jsonb, 'public'),
 ('${PBV}', '${V}', '${A}', 'stays-v', '[]'::jsonb, 'public'),
 ('${PMD1}', '${MD}', '${A}', 'doomed-a', '[]'::jsonb, 'public'),
 ('${PMD2}', '${MD}', '${B}', 'doomed-b', '[]'::jsonb, 'public'),
 ('${PEV1}', '${EWS}', '${E}', 'erase-me-private', '[]'::jsonb, 'private'),
 ('${PEV2}', '${EWS}', '${E}', 'erase-me-shared', '[]'::jsonb, 'shared'),
 ('${PKW}', '${EWS}', '${K}', 'erase-keeper', '[]'::jsonb, 'public'),
 ('${PC9}', '${W}', '${B}', 'revert-me', '[]'::jsonb, 'public'),
 ('${PBM}', '${V}', '${B}', 'benchmark', '[]'::jsonb, 'public'),
 ('${PKMD}', '${MD}', '${K}', 'cascade-pin', '[]'::jsonb, 'public');
INSERT INTO public.osionos_published_pages (page_id, owner_id, title, icon, content)
SELECT p.id, p.owner_id, p.title, 'star', '[{\"id\":\"b\",\"type\":\"text\",\"content\":\"c\"}]'::jsonb
  FROM public.osionos_pages p;
" >/dev/null
}

# --- the checks, split by concern ---------------------------------------------

# The checks live next to this script, one file per concern; they are sourced
# here because they share the fixture, the counters and the psql helpers above.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=publish-cascade/checks-c1.sh
. "${DIR}/publish-cascade/checks-c1.sh"
# shellcheck source=publish-cascade/checks-c234.sh
. "${DIR}/publish-cascade/checks-c234.sh"
# shellcheck source=publish-cascade/checks-c56.sh
. "${DIR}/publish-cascade/checks-c56.sh"
# shellcheck source=publish-cascade/checks-c789.sh
. "${DIR}/publish-cascade/checks-c789.sh"
# shellcheck source=publish-cascade/checks-c10.sh
. "${DIR}/publish-cascade/checks-c10.sh"
# shellcheck source=publish-cascade/checks-c111213.sh
. "${DIR}/publish-cascade/checks-c111213.sh"

# --- main ---------------------------------------------------------------------

main() {
	start_pg
	note "postgres up (${PG_CTN}, image ${PG_IMAGE})"
	apply_fixture
	note "fixture applied (roles, stand-ins, bridge, chat, social, engagement, publish, lifecycle, hold, service-role-only)"
	seed

	if check_c1; then
		pass c1 "archive removes the snapshot; content/title/icon updates leave it"
	else
		fail c1 "archive removes the snapshot; content/title/icon updates leave it"
	fi
	if check_c2; then
		pass c2 "owner change removes the snapshot"
	else
		fail c2 "owner change removes the snapshot"
	fi
	if check_c3; then
		pass c3 "workspace change removes the snapshot"
	else
		fail c3 "workspace change removes the snapshot"
	fi
	if check_c4; then
		pass c4 "members delete removes only that owner's pages in that workspace"
	else
		fail c4 "members delete removes only that owner's pages in that workspace"
	fi
	if check_c5; then
		pass c5 "workspace delete removes its published rows"
	else
		fail c5 "workspace delete removes its published rows"
	fi
	if check_c6; then
		pass c6 "account erasure removes the owner's published rows"
	else
		fail c6 "account erasure removes the owner's published rows"
	fi
	if check_c7; then
		pass c7 "idempotent re-apply"
	else
		fail c7 "idempotent re-apply"
	fi
	if check_c8; then
		pass c8 "acl"
	else
		fail c8 "acl"
	fi
	if check_c9; then
		pass c9 "revert proof"
	else
		fail c9 "revert proof"
	fi
	if check_c10; then
		pass c10 "hot-path cost"
	else
		fail c10 "hot-path cost"
	fi
	if check_c11; then
		pass c11 "members re-key removes the old holder's snapshots"
	else
		fail c11 "members re-key removes the old holder's snapshots"
	fi
	if check_c12; then
		pass c12 "re-apply backfills stale snapshots"
	else
		fail c12 "re-apply backfills stale snapshots"
	fi
	if check_c13; then
		pass c13 "staged workspace delete removes its snapshots"
	else
		fail c13 "staged workspace delete removes its snapshots"
	fi

	printf 'passed %s failed %s\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
