#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    account-export-lock-race.sh                                               #
#                                                                              #
#    Race a replay of the erasure migration against the export worker's       #
#    claim, and prove the replay never deadlocks it.                          #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   2026-10-26 12:45 a live apply of models/ failed on this file with 40P01:
#   the replay held a ShareLock on osionos_account_exports (its CREATE INDEX IF
#   NOT EXISTS lines), the export worker's osionos_account_export_claim() then
#   queued for RowExclusiveLock behind it, and the replay's ENABLE ROW LEVEL
#   SECURITY asked for AccessExclusiveLock on the same table. The runner
#   replays every file on every apply, and the worker polls all day, so the
#   race is on every deploy.
#
# WHAT IT RUNS
#   A throwaway grobase postgres (--rm --network none) -> 001 -> 012 -> shim
#   -> the real runner -> ROUNDS rounds. Each round queues one export job for
#   its own user, then starts a replay of the erasure file and CLAIMERS export
#   workers at once, each calling the claim CLAIM_CALLS times as service_role.
#   Every error output is read for 40P01 (deadlock) and 55P03 (lock timeout),
#   and the round's job is read back: it must be 'running', or nothing claimed.
#
# THE RESULT
#   RESULT: <n> runs, <d> deadlocks (40P01), <t> lock timeouts (55P03)
#   Exit 0 when no round deadlocked and every round's job was claimed, 1
#   otherwise, 2 when the stage could not be built.
#
# Caveat: one round is one attempt at the interleaving. Zero deadlocks in the
#   default 20 rounds is evidence, not a proof of absence; ROUNDS raises it.
# Caveat: a 55P03 is the file's own 5 s lock_timeout giving up on a busy table:
#   a failed apply that the next run retries, reported apart from deadlocks.
#
# ISOLATION
#   A throwaway container with a $$ name and a cleanup trap. The live
#   mini-baas / osionos containers are never read, written or stopped.
#
# Usage:  [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] [ROUNDS=20] sh scripts/verify/account-export-lock-race.sh
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${REPO}/scripts/verify"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_SQL="${REPO}/apps/grobase/scripts/migrations/postgresql"
ERASURE_MIGRATION="${MODELS_DIR:-${REPO}/models}/osionos-account-erasure-migration.sql"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
ROUNDS="${ROUNDS:-20}"
CLAIMERS="${CLAIMERS:-3}"
CLAIM_CALLS="${CLAIM_CALLS:-40}"

CTN=''
WORK=''
deadlocks=0
timeouts=0
errors=0

note() { printf '[account-export-lock-race] %s\n' "$*" >&2; }

cleanup() {
	[ -z "${CTN}" ] || docker rm -f "${CTN}" >/dev/null 2>&1 || true
	[ -z "${WORK}" ] || rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

psql_in() {
	docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

apply() {
	psql_in <"$1" >"${WORK}/apply.log" 2>&1 && return 0
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

boot() {
	CTN="account-export-lock-race-$$"
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null 2>&1 || { note "${IMAGE} did not start"; return 1; }
	i=0
	until docker exec "${CTN}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
		i=$((i + 1))
		[ "${i}" -lt 60 ] || { note "pg_isready never answered in 60s"; return 1; }
		sleep 1
	done
	apply "${FIX}/models-grants/roles.sql" || return 1
	grep -v '^#' "${GROBASE_SQL}/001_initial_schema.sql" >"${WORK}/001.sql"
	apply "${WORK}/001.sql" || return 1
	grep -v '^#' "${GROBASE_SQL}/012_realtime_triggers_all_tables.sql" >"${WORK}/012.sql"
	apply "${WORK}/012.sql" || return 1
	apply "${FIX}/models-grants/shim.sql" || return 1
	PG_CONTAINER="${CTN}" sh "${RUNNER}" >"${WORK}/runner.log" 2>&1 && return 0
	note "the runner failed"
	sed 's/^/  | /' "${WORK}/runner.log" >&2
	return 1
}

# The user of round n: a fixed prefix and the round number, so a round's job
# is never another round's (the table allows one active export per user).
round_user() { printf '00000000-0000-4000-8000-%012d' "$1"; }

count_sqlstates() {
	label="$1" file="$2"
	if grep -q '40P01\|deadlock detected' "${file}" 2>/dev/null; then
		deadlocks=$((deadlocks + 1))
		note "round ${n}: DEADLOCK in ${label}"
		sed 's/^/  | /' "${file}" >&2
	elif grep -q '55P03\|lock timeout' "${file}" 2>/dev/null; then
		timeouts=$((timeouts + 1))
		note "round ${n}: LOCK TIMEOUT in ${label}"
	elif grep -q 'ERROR:' "${file}" 2>/dev/null; then
		errors=$((errors + 1))
		note "round ${n}: ERROR in ${label}"
		sed 's/^/  | /' "${file}" >&2
	fi
}

round() {
	n="$1"
	user="$(round_user "${n}")"
	psql_in >/dev/null <<SQL
INSERT INTO auth.users (id, email) VALUES ('${user}', 'export-race-${n}@example.com');
INSERT INTO public.osionos_account_exports (user_id, format) VALUES ('${user}', 'json');
SQL
	psql_in <"${ERASURE_MIGRATION}" >/dev/null 2>"${WORK}/replay-${n}.err" &
	pids="$!"
	c=0
	while [ "${c}" -lt "${CLAIMERS}" ]; do
		c=$((c + 1))
		awk -v calls="${CLAIM_CALLS}" 'BEGIN { print "SET ROLE service_role;";
			for (i = 0; i < calls; i++) print "SELECT id FROM public.osionos_account_export_claim();" }' |
			psql_in >/dev/null 2>"${WORK}/claim-${n}-${c}.err" &
		pids="${pids} $!"
	done
	for pid in ${pids}; do wait "${pid}" || true; done
	count_sqlstates replay "${WORK}/replay-${n}.err"
	c=0
	while [ "${c}" -lt "${CLAIMERS}" ]; do
		c=$((c + 1))
		count_sqlstates "claim ${c}" "${WORK}/claim-${n}-${c}.err"
	done
	status="$(psql_in -At -c "SELECT coalesce((SELECT status FROM public.osionos_account_exports WHERE user_id = '${user}'), '-')")"
	[ "${status}" = running ] && return 0
	errors=$((errors + 1))
	note "round ${n}: the job was not claimed (status '${status}')"
}

main() {
	command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 2; }
	for f in "${RUNNER}" "${ERASURE_MIGRATION}" "${GROBASE_SQL}/001_initial_schema.sql"; do
		[ -f "${f}" ] || { note "no ${f}"; exit 2; }
	done
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/account-export-lock-race.XXXXXX")"
	boot || exit 2
	done_rounds=0
	while [ "${done_rounds}" -lt "${ROUNDS}" ]; do
		done_rounds=$((done_rounds + 1))
		round "${done_rounds}"
	done
	printf 'RESULT: %s runs, %s deadlocks (40P01), %s lock timeouts (55P03)\n' \
		"${ROUNDS}" "${deadlocks}" "${timeouts}"
	[ "${errors}" -eq 0 ] || { note "${errors} round(s) errored or left their job unclaimed"; exit 1; }
	[ "${deadlocks}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
