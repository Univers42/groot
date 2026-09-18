#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#    reencrypt-mounts.sh                                                       #
#                                                                              #
#    Repair live-database mounts whose stored DSN ciphertext no longer opens    #
#    under the CURRENT VAULT_ENC_KEY. Idempotent — healthy mounts are skipped.  #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   tenant_databases stores each mount's DSN inline-encrypted: scrypt(VAULT_ENC_KEY,
#   per-row salt) → AES-256-GCM. The key is NOT derived from anything persistent —
#   on a machine with no vault42 keystore, `secrets-ensure` falls into LOCAL mode
#   and grobase SELF-GENERATES its secrets, VAULT_ENC_KEY among them. Regenerate
#   that key while the database survives and every previously stored ciphertext is
#   orphaned: GET /databases/{id}/connect 500s for every mount, of every tenant,
#   and the osionos Databases navigator shows "request failed with 500" on all of
#   them. Nothing is corrupt — the rows are simply sealed with a lost key.
#
#   Diagnosis is one comparison: register a mount NOW and /connect it (200 — the
#   current key works), then /connect an old one (500). Same code path, same
#   tenant; the only variable is when the ciphertext was written.
#
# HOW IT REPAIRS
#   The adapter-registry exposes no UPDATE route, and re-registering would mint a
#   NEW mount id — breaking every reference (osionos_workspace_databases rows, the
#   app's baked VITE_BAAS_LIVE_MOUNTS). So instead: register a TEMP mount with the
#   correct DSN, let the registry encrypt it under the current key, copy the four
#   opaque ciphertext columns onto the original row, and drop the temp mount. Mount
#   ids, names, tenants, read_scoped and shared_resources are all preserved.
#
#   This script therefore never reads, derives or handles VAULT_ENC_KEY — the
#   registry performs every encryption. The DSNs are rebuilt from the engine
#   containers' own env, exactly as the seeders first built them, and are never
#   printed.
#
# Usage:  bash scripts/reencrypt-mounts.sh [--check]
#           --check  report which mounts are broken; change nothing.
#
# Only the osionos demo mounts are repaired — the DSNs of other tenants' mounts
# (website, vault42, red-tetris, gourmand) are owned by THEIR contracts and are
# reported, not guessed at.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG_URL="${ADAPTER_REGISTRY_URL:-http://127.0.0.1:3021}"
REG_CTN="${ADAPTER_REGISTRY_CONTAINER:-mini-baas-adapter-registry-go}"
PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"
TENANT="${OSIONOS_BAAS_TENANT_ID:-agency}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

note() { printf '[mounts] %s\n' "$*" >&2; }
die()  { printf '[mounts] ✗ %s\n' "$*" >&2; exit 1; }

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
cenv() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n "s/^$2=//p" | head -1; }
urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

load_service_auth() {
	local lib="${REPO_ROOT}/apps/grobase/scripts/lib/service-auth.sh"
	[ -f "${lib}" ] || die "missing ${lib}"
	# shellcheck source=/dev/null
	. "${lib}"
	SERVICE_TOKEN="$(cenv "${REG_CTN}" ADAPTER_REGISTRY_SERVICE_TOKEN)"
	export SERVICE_TOKEN
	[ -n "${SERVICE_TOKEN}" ] || die "no adapter-registry service token — is ${REG_CTN} running?"
}

# HTTP status of GET /databases/{id}/connect. 200 = ciphertext opens.
connect_code() {
	svc_auth GET "/databases/$1/connect" ""
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
		"${SVC_AUTH[@]}" -H "X-Baas-User-Id: ${TENANT}" -H "X-Baas-Tenant-Id: ${TENANT}" \
		"${REG_URL}/databases/$1/connect"
}

# Rebuild the DSN for a mount by name, exactly as its seeder first built it.
# Echoes nothing (and returns 1) when the engine it needs is unavailable.
dsn_for() {
	local name="$1" u p
	case "${name}" in
	pg-commerce|agency-db)
		running "${PG_CTN}" || return 1
		u="$(cenv "${PG_CTN}" POSTGRES_USER)"; p="$(cenv "${PG_CTN}" POSTGRES_PASSWORD)"
		[ -n "${u}" ] && [ -n "${p}" ] || return 1
		local db=commerce; [ "${name}" = "agency-db" ] && db=agency
		printf 'postgres://%s:%s@postgres:5432/%s' "$(urlenc "${u}")" "$(urlenc "${p}")" "${db}"
		;;
	mysql-ops)
		running mini-baas-mysql || return 1
		u="$(cenv mini-baas-mysql MYSQL_USER)"; p="$(cenv mini-baas-mysql MYSQL_PASSWORD)"
		if [ -z "${u}" ] || [ -z "${p}" ]; then
			u=root; p="$(cenv mini-baas-mysql MYSQL_ROOT_PASSWORD)"
		fi
		[ -n "${p}" ] || return 1
		printf 'mysql://%s:%s@mysql:3306/ops' "$(urlenc "${u}")" "$(urlenc "${p}")"
		;;
	mongo-activity)
		running mini-baas-mongo || return 1
		u="$(cenv mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"
		p="$(cenv mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"
		[ -n "${u}" ] && [ -n "${p}" ] || return 1
		printf 'mongodb://%s:%s@mongo:27017/activity?authSource=admin' "$(urlenc "${u}")" "$(urlenc "${p}")"
		;;
	osionos-restaurant)
		# The router's own ephemeral /tmp — no credential, no engine to check.
		printf 'sqlite:///tmp/osionos-restaurant.db'
		;;
	osionos-finance)
		running mini-baas-mssql || return 1
		p="$(cenv mini-baas-mssql MSSQL_SA_PASSWORD)"
		[ -n "${p}" ] || return 1
		printf 'mssql://sa:%s@mssql:1433/finance' "${p}"
		;;
	osionos-iot)
		# dynamodb-local takes static fake credentials by design.
		printf 'dynamodb://local?endpoint=http://dynamodb-local:8000&region=us-east-1&access_key=fake&secret_key=fake'
		;;
	*) return 1 ;;
	esac
}

# Register a temp mount holding `dsn`, echo its id.
register_temp() {
	local engine="$1" dsn="$2" name="$3" resp
	resp="$(python3 - "${REG_URL}" "${TENANT}" "${engine}" "${name}" "${dsn}" <<'PY'
import json, sys, urllib.request
url, tenant, engine, name, dsn = sys.argv[1:6]
body = json.dumps({"engine": engine, "name": name, "connection_string": dsn,
                   "isolation": "shared_rls"}).encode()
req = urllib.request.Request(url + "/databases", data=body, method="POST",
                             headers={"Content-Type": "application/json",
                                      "X-Baas-User-Id": tenant,
                                      "X-Baas-Tenant-Id": tenant})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(json.load(r).get("id", ""))
except Exception:
    print("")
PY
)"
	printf '%s' "${resp}"
}

# Move the four ciphertext columns from src row to dst row, then drop src.
adopt_ciphertext() {
	local dst="$1" src="$2"
	docker exec "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtAc "
		UPDATE public.tenant_databases dst
		   SET connection_enc  = src.connection_enc,
		       connection_iv   = src.connection_iv,
		       connection_tag  = src.connection_tag,
		       connection_salt = src.connection_salt
		  FROM public.tenant_databases src
		 WHERE dst.id = '${dst}'::uuid AND src.id = '${src}'::uuid;
		DELETE FROM public.tenant_databases WHERE id = '${src}'::uuid;" >/dev/null
}

main() {
	command -v docker >/dev/null 2>&1 || die "docker is required"
	command -v python3 >/dev/null 2>&1 || die "python3 is required"
	running "${REG_CTN}" || { note "${REG_CTN} not running — skipping"; exit 0; }
	running "${PG_CTN}"  || { note "${PG_CTN} not running — skipping"; exit 0; }
	load_service_auth

	local broken=0 repaired=0 id name engine code dsn tmp tmpname
	while IFS='|' read -r id name engine; do
		[ -n "${id}" ] || continue
		code="$(connect_code "${id}")"
		if [ "${code}" = "200" ]; then
			continue
		fi
		broken=$((broken + 1))
		note "${name} (${engine}): /connect → ${code}"
		[ "${CHECK_ONLY}" -eq 1 ] && continue

		if ! dsn="$(dsn_for "${name}")"; then
			note "  ↳ engine unavailable — cannot rebuild its DSN; re-run once it is up"
			continue
		fi
		tmpname="zz-reenc-$(printf '%s' "${name}" | tr -c 'a-z0-9-' '-')"
		tmp="$(register_temp "${engine}" "${dsn}" "${tmpname}")"
		if [ -z "${tmp}" ]; then
			note "  ↳ temp registration failed — left untouched"
			continue
		fi
		adopt_ciphertext "${id}" "${tmp}"
		code="$(connect_code "${id}")"
		if [ "${code}" = "200" ]; then
			note "  ↳ repaired (/connect → 200)"
			repaired=$((repaired + 1))
		else
			note "  ↳ still ${code} after re-encryption — needs a look"
		fi
	done < <(docker exec "${PG_CTN}" psql -U postgres -d postgres -qtAc \
		"SELECT id::text||'|'||name||'|'||engine FROM public.tenant_databases
		  WHERE tenant_id = '${TENANT}' ORDER BY name;" 2>/dev/null)

	if [ "${broken}" -eq 0 ]; then
		note "all '${TENANT}' mounts open under the current key"
		exit 0
	fi
	if [ "${CHECK_ONLY}" -eq 1 ]; then
		note "${broken} mount(s) need repair — run: make mounts-reencrypt"
		exit 1
	fi
	note "repaired ${repaired}/${broken}"
}

main "$@"
