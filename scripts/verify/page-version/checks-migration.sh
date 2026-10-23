# page-version/checks-migration.sh — what the migration itself guarantees: that
# it runs twice without drift, and that only the service role may append (c6–c7).
#
# Sourced by scripts/verify/page-version.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

# --- c6: the migration is re-runnable ----------------------------------------

snapshot() {
	q "
SELECT 'column|' || column_name || '|' || data_type || '|' || is_nullable || '|' || column_default
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'osionos_pages' AND column_name = 'version';
SELECT 'trigger|' || tgname || '|' || pg_get_triggerdef(oid)
  FROM pg_trigger
 WHERE tgrelid = 'public.osionos_pages'::regclass AND NOT tgisinternal ORDER BY tgname;
SELECT 'func|' || md5(prosrc) FROM pg_proc
 WHERE oid = 'public.osionos_page_append(uuid,jsonb,text,text)'::regprocedure;
SELECT 'priv|' || rolname || '|' || has_function_privilege(rolname, 'public.osionos_page_append(uuid,jsonb,text,text)', 'EXECUTE')
  FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') ORDER BY rolname;
SELECT 'tblpriv|' || rolname || '|' || has_table_privilege(rolname, 'public.osionos_page_append_keys', 'SELECT,INSERT,UPDATE,DELETE')
  FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') ORDER BY rolname;
SELECT 'rows|' || id || '|' || version FROM public.osionos_pages ORDER BY id;
"
}

check_idempotent_apply() {
	snapshot >"${WORK}/snap1.out"
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	snapshot >"${WORK}/snap2.out"
	if diff -u "${WORK}/snap1.out" "${WORK}/snap2.out" >"${WORK}/snap.diff" 2>&1; then
		printf 'PASS c6 idempotent-apply  re-running the migration twice changed no column, trigger, function, ACL or stored version\n'
	else
		printf 'FAIL c6 idempotent-apply  the re-run drifted:\n'
		sed 's/^/  | /' "${WORK}/snap.diff" >&2
		return 1
	fi
	trg="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_pages'::regclass AND tgname = 'osionos_pages_version_trg'")"
	if [ "${trg}" = "1" ]; then
		printf 'PASS c6 one-trigger       exactly one osionos_pages_version_trg on osionos_pages\n'
	else
		printf 'FAIL c6 one-trigger       %s version triggers on osionos_pages (expected 1)\n' "${trg}"
		return 1
	fi
	return 0
}

# --- c7: the ACL -------------------------------------------------------------

# probe <role> <sql> — the statement must be refused with SQLSTATE 42501.
probe_denied() {
	err="${WORK}/probe-$1.err"
	printf '%s\n' '\set VERBOSITY sqlstate' 'BEGIN;' "SET LOCAL ROLE $1;" "$2;" 'ROLLBACK;' |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/probe-$1.out" 2>"${err}" && rc=0 || rc=$?
	codes="$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | sort -u | tr '\n' ' ')"
	if [ "${rc}" -ne 0 ] && [ "${codes}" = "42501 " ]; then
		return 0
	fi
	return 1
}

check_acl() {
	append_call="SELECT * FROM public.osionos_page_append('${P4}', '[{\"id\":\"acl\",\"type\":\"text\",\"content\":\"a\"}]'::jsonb, NULL, 'acl-1')"
	if probe_denied anon "${append_call}"; then
		printf 'PASS c7 anon-denied       anon cannot execute the function (42501)\n'
	else
		printf 'FAIL c7 anon-denied       anon was NOT refused\n'
		return 1
	fi
	if probe_denied authenticated "${append_call}"; then
		printf 'PASS c7 authenticated-denied authenticated cannot execute the function (42501)\n'
	else
		printf 'FAIL c7 authenticated-denied authenticated was NOT refused\n'
		return 1
	fi
	out="$(q "BEGIN; SET LOCAL ROLE service_role; ${append_call}; COMMIT;" 2>&1 || true)"
	if printf '%s' "${out}" | grep -q 'acl'; then
		printf 'PASS c7 service-role      service_role CAN execute the function\n'
	else
		printf 'FAIL c7 service-role      service_role could NOT execute the function: %s\n' "${out}"
		return 1
	fi
	tbl="$(q "SELECT count(*) FROM pg_roles r WHERE r.rolname IN ('anon','authenticated') AND has_table_privilege(r.rolname, 'public.osionos_page_append_keys', 'SELECT,INSERT,UPDATE,DELETE')")"
	if [ "${tbl}" = "0" ]; then
		printf 'PASS c7 keys-table        anon and authenticated hold no privilege on osionos_page_append_keys\n'
	else
		printf 'FAIL c7 keys-table        %s role(s) still hold a privilege on the keys table\n' "${tbl}"
		return 1
	fi
	return 0
}
