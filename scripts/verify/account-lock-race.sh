#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    account-lock-race.sh                                                      #
#                                                                              #
#    Race the account plane's writers against each other and against a        #
#    replay of the migration file, and prove they never deadlock.              #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   The account plane's tables are written by two paths that take their locks
#   in a fixed order: a sign-in rewrites osionos_bridge_identities (and its
#   trigger rewrites the profile), and the account route writes
#   osionos_profiles. The migration file takes the same order —
#   public.users, then osionos_bridge_identities, then the profile tables —
#   so a replay of it cannot deadlock a sign-in or a profile write. A deadlock
#   (SQLSTATE 40P01) between them is a boot that fails, so the order is a
#   thing to prove, not to assume.
#
# WHAT IT RUNS
#   A throwaway grobase postgres (--rm --network none) -> 001 -> 012 -> shim
#   -> the real runner (scripts/apply-models-migrations.sh) -> 20 rounds, each
#   with four statements in flight at once:
#     1. a replay of models/osionos-account-profiles-migration.sql (it takes
#        the table locks the hot paths want);
#     2. a sign-in: UPDATE osionos_bridge_identities SET profile = ... (the
#        trigger then writes the profile);
#     3. a profile write for the SAME user: UPDATE osionos_profiles SET bio;
#     4. the atomic username change for the SAME user: the call to
#        osionos_account_change_username, as the account role with forged
#        claims, with a fresh name every round.
#   Every statement's error output is read for 40P01 (deadlock) and 55P03
#   (lock timeout), and after every round both rows are read back: the
#   identity row and the profile row must hold the round's name.
#
# THE RESULT
#   RESULT: <n> runs, <d> deadlocks (40P01), <t> lock timeouts (55P03)
#   Exit 0 when no round deadlocked AND every round moved the name to the
#   round's own name, 1 otherwise. The read-back is what makes the exit code
#   mean something: a function that writes nothing at all deadlocks nothing
#   either, and without it this script would pass a function that never ran.
#
# Caveat: the file's own lock_timeout is 5 s, so a writer that holds a lock
#   for longer than that makes the REPLAY abort with 55P03 — a failed boot
#   until the next one, not a deadlock. The timeout is reported apart from the
#   deadlocks, because a timeout is a budget and a deadlock is a bug.
#
# Caveat: the function's own lock_timeout is 3 s, so a replay that holds the
#   identities table longer than that makes every round fail with 55P03 and
#   no name move. The read-back catches that too: such a run exits 1 instead
#   of reporting a race that never happened.
#
# Caveat: one round is one attempt at the race. A deadlock that needs a
#   particular interleaving may not show up in 20 rounds; the round count is
#   the evidence, not a proof of absence.
#
# ISOLATION
#   A throwaway container with a $$ name and a cleanup trap. The live
#   mini-baas / osionos containers are never read, written or stopped.
#
# Usage:  [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] sh scripts/verify/account-lock-race.sh
# Exit:  0 no deadlock and every round moved the name · 1 a deadlock, a leg
#        that errored, or a round whose name did not move · 2 docker missing
#
# Ponytail: P1-2s extends this with the atomic username change (one SECURITY
#   DEFINER function that writes the identity row first and the profile
#   second, so it takes the same lock order as the replay and the two
#   statements above). The function carries its own 3 s lock_timeout, so a
#   replay that holds the identities table longer than that makes the call
#   fail with 55P03 — counted apart from the deadlocks, because a timeout is a
#   budget and a deadlock is a bug.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${REPO}/scripts/verify"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_INIT="${REPO}/apps/grobase/scripts/migrations/postgresql/001_initial_schema.sql"
GROBASE_REALTIME="${REPO}/apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql"
PROFILE_MIGRATION="${MODELS_DIR:-${REPO}/models}/osionos-account-profiles-migration.sql"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
READY_TIMEOUT=60
PG_USER=postgres
PG_DB=postgres
ROUNDS="${ROUNDS:-20}"
# The user every statement races for.
RACE_USER='11111111-1111-1111-1111-111111111111'

CTN=''
WORK=''
deadlocks=0
timeouts=0
errors=0

note() { printf '[account-lock-race] %s\n' "$*" >&2; }

cleanup() {
	if [ -n "${CTN}" ]; then
		docker rm -f "${CTN}" >/dev/null 2>&1 || true
	fi
	CTN=''
	rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

psql_stdin() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q
}

# The read-back: one row, one line, the identity's name and the profile's
# name separated by a pipe. -At so the answer is the value itself.
psql_at() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q -At
}

apply() {
	if psql_stdin <"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

wait_ready() {
	i=0
	while [ "${i}" -lt "${READY_TIMEOUT}" ]; do
		if docker exec "${CTN}" pg_isready -h 127.0.0.1 -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# The fixture: a user with an auth.users row, a public.users row and an
# identity row, so the sign-in and the profile write both have a row to work
# on.
seed_race_user() {
	psql_stdin >/dev/null 2>&1 <<SQL
INSERT INTO auth.users (id, email) VALUES ('${RACE_USER}', 'lockrace@example.com')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO public.users (id, email, name) VALUES ('${RACE_USER}', 'lockrace@example.com', 'Lock Race')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name)
VALUES ('prismatica', '21111111-1111-1111-1111-111111111111', '${RACE_USER}', 'lockracehash', 'Lock Race')
  ON CONFLICT DO NOTHING;
SQL
}

# One round: the replay, the sign-in, the profile write and the username
# change, all in flight. The four error files are read for the two SQLSTATEs
# that matter.
round() {
	n="$1"
	# 1. the replay of the migration file
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		<"${PROFILE_MIGRATION}" >"${WORK}/replay-${n}.out" 2>"${WORK}/replay-${n}.err" &
	replay_pid=$!
	# 2. the sign-in: the identity row's blob moves
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/signin-${n}.out" 2>"${WORK}/signin-${n}.err" <<SQL &
UPDATE public.osionos_bridge_identities SET profile = '{"headline":"race ${n}"}' WHERE user_id = '${RACE_USER}';
SQL
	signin_pid=$!
	# 3. the profile write, for the same user
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/profile-${n}.out" 2>"${WORK}/profile-${n}.err" <<SQL &
UPDATE public.osionos_profiles SET bio = 'race ${n}' WHERE user_id = '${RACE_USER}';
SQL
	profile_pid=$!
	# 4. the atomic username change, for the same user, as the account role
	#    with forged claims and a fresh name every round
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/username-${n}.out" 2>"${WORK}/username-${n}.err" <<SQL &
BEGIN;
SET LOCAL ROLE osionos_account_user;
SELECT set_config('request.jwt.claims', '{"sub":"${RACE_USER}","aud":"osionos-account","role":"osionos_account_user"}', true);
SELECT public.osionos_account_change_username('race${n}');
COMMIT;
SQL
	username_pid=$!
	wait "${replay_pid}" || true
	wait "${signin_pid}" || true
	wait "${profile_pid}" || true
	wait "${username_pid}" || true
	for f in "${WORK}"/replay-"${n}".err "${WORK}"/signin-"${n}".err "${WORK}"/profile-"${n}".err "${WORK}"/username-"${n}".err; do
		if grep -q '40P01\|deadlock detected' "${f}" 2>/dev/null; then
			deadlocks=$((deadlocks + 1))
			note "round ${n}: DEADLOCK in $(basename "${f}")"
			sed 's/^/  | /' "${f}" >&2
		fi
		if grep -q '55P03\|lock timeout' "${f}" 2>/dev/null; then
			timeouts=$((timeouts + 1))
			note "round ${n}: LOCK TIMEOUT in $(basename "${f}")"
			sed 's/^/  | /' "${f}" >&2
		fi
	done
	# The username leg must not fail for any other reason: a leg that errors
	# is a round that proved nothing, and a race that silently stopped
	# running looks exactly like a race that never deadlocked.
	if grep -q 'ERROR:' "${WORK}/username-${n}.err" 2>/dev/null &&
		! grep -q '40P01\|deadlock detected\|55P03\|lock timeout' "${WORK}/username-${n}.err" 2>/dev/null; then
		errors=$((errors + 1))
		note "round ${n}: ERROR in username-${n}.err"
		sed 's/^/  | /' "${WORK}/username-${n}.err" >&2
	fi
	# THE ROUND MUST HAVE MOVED THE NAME. Without this a function that writes
	# nothing at all passes the race: no deadlock, no error, exit 0, and
	# nothing was ever raced. Both rows are read back in a fresh session,
	# after the change committed.
	back="$(psql_at <"${WORK}/readback.sql" 2>/dev/null || true)"
	if [ "${back}" != "race${n}|race${n}" ]; then
		errors=$((errors + 1))
		note "round ${n}: the name did not move (read back '${back}', wanted 'race${n}|race${n}')"
	fi
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	[ -f "${RUNNER}" ] || {
		note "no ${RUNNER}"
		exit 2
	}
	[ -f "${PROFILE_MIGRATION}" ] || {
		note "no ${PROFILE_MIGRATION}"
		exit 2
	}
	CTN="account-lock-race-$$"
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/account-lock-race.XXXXXX")"
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null 2>&1 || {
		note "${IMAGE} did not start"
		exit 2
	}
	wait_ready || {
		note "pg_isready never answered in ${READY_TIMEOUT}s"
		exit 2
	}
	apply "${FIX}/models-grants/roles.sql" || exit 2
	grep -v '^#' "${GROBASE_INIT}" >"${WORK}/001.sql" || exit 2
	apply "${WORK}/001.sql" || exit 2
	grep -v '^#' "${GROBASE_REALTIME}" >"${WORK}/012.sql" || exit 2
	apply "${WORK}/012.sql" || exit 2
	apply "${FIX}/models-grants/shim.sql" || exit 2
	PG_CONTAINER="${CTN}" sh "${RUNNER}" >"${WORK}/runner.log" 2>&1 || {
		note "the runner failed"
		sed 's/^/  | /' "${WORK}/runner.log" >&2
		exit 2
	}
	seed_race_user || {
		note "the race user could not be created"
		exit 2
	}
	# The read-back query, written once: the identity's name and the
	# profile's name, separated by a pipe. A name that is not there reads
	# '-' rather than nothing, so a missing row is a wrong answer and not an
	# empty one.
	printf '%s\n' \
		"SELECT coalesce((SELECT username FROM public.osionos_bridge_identities WHERE user_id = '${RACE_USER}'), '-')" \
		"    || '|' || coalesce((SELECT username FROM public.osionos_profiles WHERE user_id = '${RACE_USER}'), '-');" \
		>"${WORK}/readback.sql"
	i=0
	while [ "${i}" -lt "${ROUNDS}" ]; do
		i=$((i + 1))
		round "${i}"
	done
	printf 'RESULT: %s runs, %s deadlocks (40P01), %s lock timeouts (55P03)\n' \
		"${ROUNDS}" "${deadlocks}" "${timeouts}"
	[ "${errors}" -eq 0 ] || {
		note "${errors} round(s) failed the username change: an error other than a deadlock or a timeout, or a name that did not move"
		exit 1
	}
	[ "${deadlocks}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
