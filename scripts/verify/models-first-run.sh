#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    models-first-run.sh                                                       #
#                                                                              #
#    Prove that scripts/apply-models-migrations.sh reports 0 failures on the   #
#    FIRST run against an EMPTY database — the one case a developer machine    #
#    can never test, because its own database is already converged.            #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   `make all` failed at models-migrate on a fresh clone and nowhere else. The
#   runner applies models/*.sql in plain alphabetical glob order, and several
#   files reference a table/column/function that a LATER-alphabetical file
#   creates. On a machine that has run the pipeline before, every one of those
#   objects already exists, so the true first-run order is never exercised and
#   the bug is invisible. An evaluator gets exactly one first run.
#
#   This script brings up ONLY the grobase database path in a SEPARATE compose
#   project on FRESH volumes, applies the migrations, and reports the failures.
#   The live `mini-baas` stack is never read, written, stopped or touched.
#
# WHAT IT BRINGS UP  (the real chain, see apps/grobase/docker-compose.yml)
#   postgres -> db-bootstrap -> mailpit + gotrue -> pg-migrate
#     apps/grobase/orchestrators/compose/base/data-engines.yml:7,73,113
#     apps/grobase/orchestrators/compose/base/auth-api.yml:3,86
#   pg-migrate applies grobase's own scripts/migrations/postgresql/*.sql; the
#   models/*.sql pass under test runs after it, exactly as in
#   infrastructure/makes/pipeline.mk:5 -> infrastructure/makes/baas.mk:92.
#
# ISOLATION
#   - Separate compose project (--project-name below), so every named volume is
#     project-prefixed and starts empty.
#   - models-first-run.override.yml renames every container (the base files pin
#     container_name: mini-baas-*, which would collide with the live stack) and
#     publishes NO host ports.
#   - Teardown removes this project's containers and names its two volumes
#     explicitly. It never runs `down -v` and never touches a mini-baas volume.
#
# Usage:  sh scripts/verify/models-first-run.sh [-l LABEL] [-s RUNNER] [-k]
#   -l LABEL   output subdirectory name under $OUT_DIR   (default: first-run)
#   -s RUNNER  runner under test  (default: scripts/apply-models-migrations.sh)
#   -k         keep the project up afterwards, for manual psql probing
#   -h         this help
#
# Env:  OUT_DIR   where logs land          (default: ~/t15)
#       PROJECT   compose project name     (default: t1repro)
#
# Exit:  0  first pass reported 0 failures
#        1  first pass reported failures, or a prerequisite container failed
#        2  misuse
#
# Output: $OUT_DIR/$LABEL/{pass1.out,pass2.out,compose-up.log,pg-migrate.log,
#         db-bootstrap.log} — pass1.out is the artifact to read on failure; the
#         runner names the first ERROR line of the migration that failed.
#
# Ponytail: a PASS means only that psql accepted every statement on an empty
# database. It does not check that the resulting schema matches the live one,
# and it cannot see a dependency that a file satisfies by accident (e.g. two
# files that both CREATE the same table IF NOT EXISTS). It also assumes the
# grobase images are already pulled — it runs `up --no-build --pull never` so
# that a missing image fails fast instead of triggering a silent 10-minute
# build.
set -eu

LABEL=first-run
KEEP=0
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
OUT_DIR="${OUT_DIR:-${HOME}/t15}"
PROJECT="${PROJECT:-t1repro}"

usage() {
	sed -n '/^# Usage:/,/^# Output:/p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-2}"
}

while getopts 'l:s:kh' opt; do
	case "${opt}" in
	l) LABEL="${OPTARG}" ;;
	s) RUNNER="${OPTARG}" ;;
	k) KEEP=1 ;;
	h) usage 0 ;;
	*) usage 2 ;;
	esac
done

GB="${REPO}/apps/grobase"
OVERLAY="${REPO}/scripts/verify/models-first-run.override.yml"
OUT="${OUT_DIR}/${LABEL}"
PGC="${PROJECT}-postgres"
DC="docker compose -p ${PROJECT} -f ${GB}/docker-compose.yml -f ${OVERLAY}"

note() { printf '[first-run] %s\n' "$*" >&2; }

# Only ever this project's own containers and its two named volumes.
teardown() {
	(cd "${GB}" && ${DC} down --remove-orphans >/dev/null 2>&1) || true
	docker volume rm -f "${PROJECT}_postgres-data" "${PROJECT}_redis-data" >/dev/null 2>&1 || true
}

wait_for_exit() {
	i=0
	while [ "$i" -lt 180 ]; do
		st="$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$1" 2>/dev/null || echo 'missing:-')"
		case "${st}" in exited:*) return 0 ;; esac
		i=$((i + 1))
		sleep 1
	done
	return 0
}

run_pass() {
	MODELS_DIR="${REPO}/models" PG_CONTAINER="${PGC}" sh "${RUNNER}" >"$2" 2>&1 && rc=0 || rc=$?
	note "$1: exit=${rc} — $(grep -h 'done —' "$2" || echo 'no summary line')"
	grep -h 'FAILED:' "$2" >&2 || true
	return "${rc}"
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"; exit 2
	}
	[ -f "${RUNNER}" ] || {
		note "no runner at ${RUNNER}"; exit 2
	}
	[ -f "${OVERLAY}" ] || {
		note "no overlay at ${OVERLAY}"; exit 2
	}

	mkdir -p "${OUT}"
	rm -f "${OUT}"/*.out "${OUT}"/*.log 2>/dev/null || true

	note "project ${PROJECT} — removing any leftover, then up on FRESH volumes"
	teardown
	[ "${KEEP}" -eq 1 ] || trap teardown EXIT INT TERM

	cd "${GB}"
	${DC} up -d --no-build --pull never pg-migrate >"${OUT}/compose-up.log" 2>&1 || {
		note "compose up failed — see ${OUT}/compose-up.log"
		exit 1
	}

	wait_for_exit "${PROJECT}-pg-migrate"
	docker logs "${PROJECT}-pg-migrate" >"${OUT}/pg-migrate.log" 2>&1 || true
	docker logs "${PROJECT}-db-bootstrap" >"${OUT}/db-bootstrap.log" 2>&1 || true
	case "${st}" in
	exited:0) note "pg-migrate ${st}" ;;
	*)
		note "pg-migrate ${st} — prerequisite failed, see ${OUT}/pg-migrate.log"; exit 1
		;;
	esac

	run_pass "pass 1 (from zero)" "${OUT}/pass1.out" || {
		note "FIRST RUN FAILED — read ${OUT}/pass1.out"
		exit 1
	}
	run_pass "pass 2 (idempotency)" "${OUT}/pass2.out" || {
		note "re-run is not a clean no-op — read ${OUT}/pass2.out"
		exit 1
	}
	note "0 failed on the first run — logs in ${OUT}"
	[ "${KEEP}" -eq 1 ] && note "-k given: ${PROJECT} left up (tear down: docker compose -p ${PROJECT} ... down)"
	exit 0
}

main
