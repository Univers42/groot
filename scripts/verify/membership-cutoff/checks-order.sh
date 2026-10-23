# shellcheck disable=SC2317,SC2329
#
# C131: the order the runner applies the models in, read from the runner itself.
#
# The migration's header says the runner applies it after osionos-bridge-migration.sql
# and after auth-session-cutoffs.sql. That claim is checked here, against the SOURCE of
# scripts/apply-models-migrations.sh -- the runner is never run: it applies migrations to
# a live database, and this script only ever names its own throwaway containers.
#
# The runner's passes, in order:
#   1. ORDERED_FIRST, in the order of the list;
#   2. the files of models/*.sql in the shell's own order (the glob, in the locale of
#      the shell), minus the ordered and the skipped ones;
#   3. ORDERED_LAST.
#
# The order the file under test needs: osionos-bridge-migration.sql is in ORDERED_FIRST
# (so it is applied before the alphabetical pass), auth-session-cutoffs.sql is in the
# alphabetical pass and sorts BEFORE the file under test, and the file under test is in
# neither ORDERED_FIRST nor ORDERED_LAST nor skipped().

MIGRATION_FILE="osionos-membership-cutoff-migration.sql"

# The runner's own list, read from its source.
runner_first() {
	sed -n 's/^ORDERED_FIRST="\(.*\)"$/\1/p' "$1"
}

runner_last() {
	sed -n 's/^ORDERED_LAST="\(.*\)"$/\1/p' "$1"
}

# Every file name the runner's skipped() refuses.
runner_skipped() {
	sed -n '/^skipped() {/,/^}/p' "$1" | grep -o '[a-z0-9-]*\.sql' | tr '\n' ' '
}

# The runner's alphabetical pass: the same glob, in the same shell, with the same
# locale, minus the files the other two passes own.
runner_alphabetical() {
	for f in "$1"/*.sql; do
		[ -f "${f}" ] || continue
		base="$(basename "${f}")"
		case " $(runner_first "$2") " in *" ${base} "*) continue ;; esac
		case " $(runner_last "$2") " in *" ${base} "*) continue ;; esac
		case " $(runner_skipped "$2") " in *" ${base} "*) continue ;; esac
		printf '%s ' "${base}"
	done
}

check_order() {
	runner="${REPO}/scripts/apply-models-migrations.sh"
	[ -f "${runner}" ] || { printf 'FAIL c131 order  the runner is missing\n' >&2; return 1; }

	first="$(runner_first "${runner}")"
	last="$(runner_last "${runner}")"
	skipped="$(runner_skipped "${runner}")"
	printf '[c131] runner ORDERED_FIRST: %s\n' "${first}" >&2
	printf '[c131] runner ORDERED_LAST: %s\n' "${last}" >&2
	printf '[c131] runner skipped: %s\n' "${skipped}" >&2
	printf '[c131] locale: LC_ALL=%s LC_COLLATE=%s LANG=%s\n' "${LC_ALL:-}" "${LC_COLLATE:-}" "${LANG:-}" >&2

	# The bridge migration is applied first: it creates the two tables the trigger
	# needs.
	case " ${first} " in
	*" osionos-bridge-migration.sql "*) ;;
	*)
		printf 'FAIL c131 order  osionos-bridge-migration.sql is not in ORDERED_FIRST\n' >&2
		return 1
		;;
	esac

	# The file under test is in neither pass, and is not skipped.
	case " ${first} " in
	*" ${MIGRATION_FILE} "*)
		printf 'FAIL c131 order  %s is in ORDERED_FIRST: it would run before auth-session-cutoffs.sql\n' "${MIGRATION_FILE}" >&2
		return 1
		;;
	esac
	case " ${last} " in
	*" ${MIGRATION_FILE} "*)
		printf 'FAIL c131 order  %s is in ORDERED_LAST\n' "${MIGRATION_FILE}" >&2
		return 1
		;;
	esac
	case " ${skipped} " in
	*" ${MIGRATION_FILE} "*)
		printf 'FAIL c131 order  %s is skipped by the runner\n' "${MIGRATION_FILE}" >&2
		return 1
		;;
	esac

	# The alphabetical pass: auth-session-cutoffs.sql before the file under test.
	alphabetical="$(runner_alphabetical "${MODELS}" "${runner}")"
	printf '[c131] alphabetical pass: %s\n' "${alphabetical}" >&2
	cutoffs_at=0
	migration_at=0
	position=0
	for base in ${alphabetical}; do
		position=$((position + 1))
		[ "${base}" = "auth-session-cutoffs.sql" ] && cutoffs_at="${position}"
		[ "${base}" = "${MIGRATION_FILE}" ] && migration_at="${position}"
	done
	[ "${cutoffs_at}" -gt 0 ] || { printf 'FAIL c131 order  auth-session-cutoffs.sql is not in the alphabetical pass\n' >&2; return 1; }
	[ "${migration_at}" -gt 0 ] || { printf 'FAIL c131 order  %s is not in the alphabetical pass\n' "${MIGRATION_FILE}" >&2; return 1; }
	[ "${cutoffs_at}" -lt "${migration_at}" ] || {
		printf 'FAIL c131 order  auth-session-cutoffs.sql (%s) must come before %s (%s)\n' "${cutoffs_at}" "${MIGRATION_FILE}" "${migration_at}" >&2
		return 1
	}
	printf '[c131] order: bridge (ORDERED_FIRST), auth-session-cutoffs.sql (%s), %s (%s)\n' "${cutoffs_at}" "${MIGRATION_FILE}" "${migration_at}" >&2
	return 0
}
