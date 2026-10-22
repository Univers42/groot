# page-version/checks-rest.sh — the checks that do not go through psql: the
# PostgREST surface (c8) and the revert proof of the content predicate (c9).
#
# Sourced by scripts/verify/page-version.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

# --- c8: PostgREST (U1 + U4) -------------------------------------------------

mint_jwt() {
	JWT_SECRET="${JWT_SECRET}" python3 -c '
import base64, hashlib, hmac, json, os, sys, time
role = sys.argv[1]
secret = os.environ["JWT_SECRET"].encode()
def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
now = int(time.time())
pay = b64(json.dumps({"role": role, "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
sig = b64(hmac.new(secret, head + b"." + pay, hashlib.sha256).digest())
print((head + b"." + pay + b"." + sig).decode())
' "$1"
}

start_postgrest() {
	docker run -d --name "${PGRST_CTN}" --network "${NET}" \
		-p "127.0.0.1:${PGRST_PORT}:3000" \
		-e PGRST_DB_URI="postgresql://authenticator@${PG_CTN}:5432/postgres" \
		-e PGRST_DB_SCHEMAS=public \
		-e PGRST_DB_ANON_ROLE=anon \
		-e PGRST_JWT_SECRET="${JWT_SECRET}" \
		-e PGRST_SERVER_PORT=3000 \
		"${PGRST_IMAGE}" >/dev/null
	i=0
	while [ "${i}" -lt 60 ]; do
		if curl -sS -o /dev/null "http://127.0.0.1:${PGRST_PORT}/" 2>/dev/null; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	note "postgrest never answered"
	docker logs "${PGRST_CTN}" >&2 || true
	return 1
}

check_postgrest() {
	start_postgrest || return 1
	# A bare PostgREST serves the REST API at "/" — the grobase stack puts Kong in
	# front of it and strips the /rest/v1 prefix, so the path here is the one the
	# bridge uses minus that prefix.
	base="http://127.0.0.1:${PGRST_PORT}"
	svc="$(mint_jwt service_role)"
	anon="$(mint_jwt anon)"

	# U1: a conditional PATCH that matches no row. return=representation must
	# answer 200 with [], return=minimal must answer 204.
	curl -sS -o "${WORK}/u1-rep.body" -D "${WORK}/u1-rep.head" \
		-X PATCH "${base}/osionos_pages?id=eq.${P2}&version=eq.999" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Prefer: return=representation" -H "Content-Type: application/json" \
		-d '{"title":"probe"}'
	rep_code="$(awk 'NR==1 {print $2}' "${WORK}/u1-rep.head")"
	rep_body="$(tr -d '\n' <"${WORK}/u1-rep.body")"
	printf '[U1] PATCH osionos_pages?id=eq.%s&version=eq.999 (Prefer: return=representation)\n' "${P2}" >&2
	sed 's/^/[U1] /' "${WORK}/u1-rep.head" >&2
	printf '[U1] body: %s\n' "${rep_body}" >&2

	curl -sS -o "${WORK}/u1-min.body" -D "${WORK}/u1-min.head" \
		-X PATCH "${base}/osionos_pages?id=eq.${P2}&version=eq.999" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Prefer: return=minimal" -H "Content-Type: application/json" \
		-d '{"title":"probe"}'
	min_code="$(awk 'NR==1 {print $2}' "${WORK}/u1-min.head")"
	printf '[U1] PATCH osionos_pages?id=eq.%s&version=eq.999 (Prefer: return=minimal)\n' "${P2}" >&2
	sed 's/^/[U1] /' "${WORK}/u1-min.head" >&2
	printf '[U1] body: %s\n' "$(tr -d '\n' <"${WORK}/u1-min.body")" >&2

	if [ "${rep_code}" = "200" ] && [ "${rep_body}" = "[]" ]; then
		printf 'PASS c8 u1-representation  the conditional PATCH answered 200 []\n'
	else
		printf 'FAIL c8 u1-representation  the conditional PATCH answered %s %s (expected 200 [])\n' "${rep_code}" "${rep_body}"
		return 1
	fi
	if [ "${min_code}" = "204" ]; then
		printf 'PASS c8 u1-minimal        the same PATCH with return=minimal answered 204\n'
	else
		printf 'FAIL c8 u1-minimal        the same PATCH with return=minimal answered %s (expected 204)\n' "${min_code}"
		return 1
	fi

	# U4: the append over RPC, as the service role.
	curl -sS -o "${WORK}/u4.body" -D "${WORK}/u4.head" \
		-X POST "${base}/rpc/osionos_page_append" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Content-Type: application/json" \
		-d "{\"p_page_id\":\"${P5}\",\"p_blocks\":[{\"id\":\"rpc-1\",\"type\":\"text\",\"content\":\"R\"}],\"p_after_block_id\":null,\"p_idempotency_key\":\"rpc-key-1\"}"
	u4_code="$(awk 'NR==1 {print $2}' "${WORK}/u4.head")"
	u4_body="$(tr -d '\n' <"${WORK}/u4.body")"
	printf '[U4] POST /rpc/osionos_page_append (service_role)\n' >&2
	sed 's/^/[U4] /' "${WORK}/u4.head" >&2
	printf '[U4] body: %s\n' "${u4_body}" >&2
	if [ "${u4_code}" = "200" ] && printf '%s' "${u4_body}" | grep -q 'rpc-1'; then
		printf 'PASS c8 u4-rpc             POST /rpc/osionos_page_append answered 200 with the appended block\n'
	else
		printf 'FAIL c8 u4-rpc             POST /rpc/osionos_page_append answered %s %s\n' "${u4_code}" "${u4_body}"
		return 1
	fi

	# The same call as anon must be refused.
	curl -sS -o "${WORK}/anon.body" -D "${WORK}/anon.head" \
		-X POST "${base}/rpc/osionos_page_append" \
		-H "apikey: ${anon}" -H "Authorization: Bearer ${anon}" \
		-H "Content-Type: application/json" \
		-d "{\"p_page_id\":\"${P5}\",\"p_blocks\":[{\"id\":\"rpc-anon\"}],\"p_after_block_id\":null,\"p_idempotency_key\":\"rpc-key-anon\"}"
	anon_code="$(awk 'NR==1 {print $2}' "${WORK}/anon.head")"
	printf '[ACL] POST /rpc/osionos_page_append (anon)\n' >&2
	sed 's/^/[ACL] /' "${WORK}/anon.head" >&2
	printf '[ACL] body: %s\n' "$(tr -d '\n' <"${WORK}/anon.body")" >&2
	case "${anon_code}" in
	401 | 403 | 404) printf 'PASS c8 anon-rpc          anon was refused with %s\n' "${anon_code}" ;;
	*) printf 'FAIL c8 anon-rpc          anon was NOT refused (answered %s)\n' "${anon_code}"; return 1 ;;
	esac
	return 0
}

# --- c9: the revert proof ----------------------------------------------------

check_revert_proof() {
	# The broken trigger: bump on EVERY update, the content predicate gone.
	q "
CREATE OR REPLACE FUNCTION public.osionos_page_bump_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS \$\$
BEGIN
  NEW.version := OLD.version + 1;
  RETURN NEW;
END \$\$;
" >/dev/null
	if check_metadata >"${WORK}/revert.out" 2>&1; then
		printf 'FAIL c9 revert-proof       c1 PASSED with the content predicate removed — the predicate is not what the check reads\n'
		sed 's/^/  | /' "${WORK}/revert.out" >&2
		apply "${MODELS}/osionos-page-version-migration.sql" || true
		return 1
	fi
	printf '[revert-proof] the content predicate is gone from the trigger (bump on every update):\n' >&2
	sed 's/^/[revert-proof] /' "${WORK}/revert.out" >&2
	# Restore: the migration file is the source of truth.
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	if check_metadata >"${WORK}/restored.out" 2>&1; then
		printf '[revert-proof] the migration file is applied again, and c1 passes:\n' >&2
		sed 's/^/[revert-proof] /' "${WORK}/restored.out" >&2
		printf 'PASS c9 revert-proof       with the predicate gone c1 FAILED; restoring the file made it PASS again\n'
	else
		printf 'FAIL c9 revert-proof       c1 still fails after restoring the migration file:\n'
		sed 's/^/  | /' "${WORK}/restored.out" >&2
		return 1
	fi
	return 0
}
