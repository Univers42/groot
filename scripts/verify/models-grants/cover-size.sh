# PS31 cover size gate (ADR 0067 CS4/CS5). Sourced by models-grants.sh, so it
# uses that script's psql_rows, psql_stdin, apply, check_count, pass, fail.

COVER_SIZE_SQL="${MODELS_DIR}/osionos-page-cover-size-migration.sql"

# cover_probe <scenario> <id> <values> <want> — one INSERT in a rolled-back
# transaction. want is a SQLSTATE the insert must be refused with, or "ok".
# session_replication_role = replica skips the workspace FK so no fixture row
# is needed; CHECK constraints still fire. Nothing persists.
cover_probe() {
	cp_err="${WORK}/cover-$1-$2.err"
	if printf '%s\n' '\set VERBOSITY sqlstate' 'BEGIN;' \
		'SET LOCAL session_replication_role = replica;' \
		"INSERT INTO public.osionos_pages (workspace_id, cover_height, cover_width) VALUES (gen_random_uuid(), $3);" \
		'ROLLBACK;' | psql_stdin >/dev/null 2>"${cp_err}"; then
		cp_got=ok
	else
		cp_got="$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${cp_err}" | sort -u)"
	fi
	if [ "${cp_got}" = "$4" ]; then
		pass "$1" "$2" "$4"
	else
		fail "$1" "$2" "insert ($3) gave [${cp_got:-no SQLSTATE}], want $4"
	fi
}

# cover_replay <scenario> — the file applied twice exits 0 both times and
# leaves the same state, then a second runner pass is clean.
cover_replay() {
	cr_bad=0
	apply "${COVER_SIZE_SQL}" || cr_bad=1
	apply "${COVER_SIZE_SQL}" || cr_bad=1
	if [ "${cr_bad}" = 0 ]; then
		pass "$1" "cs_replay" "the file applied twice, exit 0 both times"
	else
		fail "$1" "cs_replay" "a replay of the cover size file failed"
	fi
	run_runner "$1" "cover-size"
}

# cover_rows <scenario> <label-prefix> — the check rows, appended to the
# stream check_count reads; the prefix keeps the second read's labels apart.
cover_rows() {
	if ! psql_rows <"${FIX}/cover-size-checks.sql" >"${WORK}/cover-$1.out" 2>"${WORK}/cover-$1.err"; then
		note "cover-size-checks.sql did not run to completion"
		sed 's/^/  | /' "${WORK}/cover-$1.err" >&2
	fi
	sed "s/^cs_/$2_/" "${WORK}/cover-$1.out" >>"${WORK}/checks-$1.out"
}

# check_cover_size <scenario>
# Caveat: probes cover the CHECK bounds at one point each (100, 641, 'wide'),
# not the exact edges 120/640; BETWEEN's edges are the database's, not this gate's.
check_cover_size() {
	cover_rows "$1" cs
	check_count "$1" cs_columns cs_columns
	check_count "$1" cs_validated cs_validated
	cover_probe "$1" cs_height_low "100, NULL" 23514
	cover_probe "$1" cs_height_high "641, NULL" 23514
	cover_probe "$1" cs_width_wide "NULL, 'wide'" 23514
	cover_probe "$1" cs_null_ok "NULL, NULL" ok
	cover_probe "$1" cs_values_ok "240, 'content'" ok
	cover_replay "$1"
	cover_rows "$1" csr
	check_count "$1" cs_constraint_count csr_constraint_count
	check_count "$1" cs_validated_after_replay csr_validated
}
