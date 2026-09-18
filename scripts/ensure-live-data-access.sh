#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#    ensure-live-data-access.sh                                                #
#                                                                              #
#    Converge the osionos app's LIVE-DATABASE access: the tenant API key the    #
#    bridge presents to the query-router, and the owner principal stamped on    #
#    the seeded demo rows. Idempotent — a converged stack is a no-op.           #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   The bridge authenticates to the query-router with X-Baas-Api-Key only
#   (scripts/bridge-api.mjs). With no key it throws 503 "osionos query-router
#   access is not configured." and every live mount in the Databases navigator
#   reports that string.
#
#   The key's CLEARTEXT is returned exactly once at issue time and never
#   persisted (tenant_api_keys stores key_prefix + sha256 key_hash). So a lost
#   ./.env.local — it is gitignored, and gen-local-env.sh writes the field
#   EMPTY — is unrecoverable: the only repair is to issue a NEW key.
#
#   That is where the trap is. The data plane stamps owner_id = "api-key:<key
#   uuid>" on every row it writes and owner-scopes reads. A new key has a new
#   uuid, so the app authenticates fine and then sees ZERO rows — a silent
#   empty state, strictly worse than the honest 503. Issuing a key is therefore
#   only half a repair; the seeded rows must be re-stamped onto the new
#   principal in the same breath. This script does both, or neither.
#
# WHAT IT DOES
#   1. If ./.env.local already carries a key that /v1/keys/verify accepts AND
#      the demo rows already carry that key's principal → exit 0, silently.
#   2. Otherwise issue a key for the tenant (POST /v1/tenants/{id}/keys, HMAC
#      service auth), re-stamp every api-key:* principal in the demo databases
#      onto it, and write it to ./.env.local + apps/osionos/app/.env.
#
#   Engines that are not running are SKIPPED with a notice, never a failure:
#   the devlean edition omits mssql/dynamodb, and their mounts simply stay
#   unreadable until that edition brings them up (re-run this script then).
#
# Usage:  bash scripts/ensure-live-data-access.sh [--check]
#           --check  report convergence and exit non-zero if repair is needed;
#                    make NO changes. Used by CI and by `make healthcheck`.
#
# The key value is NEVER printed — only its uuid, prefix and the row counts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_LOCAL="${ENV_LOCAL:-${REPO_ROOT}/.env.local}"
APP_ENV="${APP_ENV:-${REPO_ROOT}/apps/osionos/app/.env}"
TENANT="${OSIONOS_BAAS_TENANT_ID:-agency}"
TC_URL="${TENANT_CONTROL_URL:-http://127.0.0.1:3022}"
PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"
MYSQL_CTN="${MYSQL_CONTAINER:-mini-baas-mysql}"
MONGO_CTN="${MONGO_CONTAINER:-mini-baas-mongo}"
TC_CTN="${TENANT_CONTROL_CONTAINER:-mini-baas-tenant-control}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

note() { printf '[live-data] %s\n' "$*" >&2; }
die()  { printf '[live-data] ✗ %s\n' "$*" >&2; exit 1; }

# Demo databases to re-stamp, as "<engine>:<database>". The osionos live demo
# owns exactly these; everything else in the stack belongs to other contracts.
PG_DBS="commerce agency"
MYSQL_DBS="ops"
MONGO_DBS="activity"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# ── service auth ────────────────────────────────────────────────────────────
# service-auth.sh is bash (it returns a SVC_AUTH array), which is why this
# script is bash and not sh.
load_service_auth() {
	local lib="${REPO_ROOT}/apps/grobase/scripts/lib/service-auth.sh"
	[ -f "${lib}" ] || die "missing ${lib} — is the apps/grobase submodule checked out?"
	# shellcheck source=/dev/null
	. "${lib}"
	if [ -z "${SERVICE_TOKEN:-}" ]; then
		SERVICE_TOKEN="$(docker inspect "${TC_CTN}" \
			--format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
			| sed -n 's/^INTERNAL_SERVICE_TOKEN=//p' | head -1)"
		export SERVICE_TOKEN
	fi
	[ -n "${SERVICE_TOKEN:-}" ] || die "no service token — is ${TC_CTN} running?"
}

# Read a key out of an env file without echoing it.
read_key_from_env() {
	[ -f "$1" ] || return 1
	sed -n "s/^${2}=//p" "$1" | head -1
}

# Verify a key against the control plane. Echoes the key's uuid on success.
verify_key() {
	local key="$1" body resp
	[ -n "${key}" ] || return 1
	body="$(printf '{"key":"%s"}' "${key}")"
	svc_auth POST /v1/keys/verify "${body}"
	resp="$(curl -s --max-time 10 -X POST "${TC_URL}/v1/keys/verify" \
		-H 'Content-Type: application/json' "${SVC_AUTH[@]}" -d "${body}" 2>/dev/null || true)"
	printf '%s' "${resp}" | grep -q '"key_id"\|"id"' || return 1
	printf '%s' "${resp}" | sed -n 's/.*"key_id":"\([^"]*\)".*/\1/p;s/.*"id":"\([^"]*\)".*/\1/p' | head -1
}

# ── stale-principal detection ───────────────────────────────────────────────
# Any api-key:* principal in the demo data that is NOT the one we hold is
# stale: rows the app can authenticate for but never see.
stale_pg() {
	local want="$1" db n=0 t
	running "${PG_CTN}" || { printf '0'; return; }
	for db in ${PG_DBS}; do
		docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='public';" 2>/dev/null \
		| while read -r t; do
			[ -n "${t}" ] || continue
			docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
				"SELECT count(*) FROM public.\"${t}\"
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null
		done | awk '{s+=$1} END {print s+0}'
	done | awk '{s+=$1} END {print s+0}'
}

restamp_pg() {
	local want="$1" db t total=0 n
	running "${PG_CTN}" || { note "postgres not running — skipped"; return; }
	for db in ${PG_DBS}; do
		while read -r t; do
			[ -n "${t}" ] || continue
			n="$(docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
				"UPDATE public.\"${t}\" SET owner_id='${want}'
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null \
				| sed -n 's/^UPDATE //p')"
			total=$((total + ${n:-0}))
		done < <(docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='public';" 2>/dev/null)
	done
	note "postgres: re-stamped ${total} rows"
}

mysql_pw() {
	docker inspect "${MYSQL_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -1
}

restamp_mysql() {
	local want="$1" db pw t total=0 n
	running "${MYSQL_CTN}" || { note "mysql not running — skipped"; return; }
	pw="$(mysql_pw)"
	for db in ${MYSQL_DBS}; do
		while read -r t; do
			[ -n "${t}" ] || continue
			docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
				"UPDATE \`${db}\`.\`${t}\` SET owner_id='${want}'
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null || true
			n="$(docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
				"SELECT ROW_COUNT();" 2>/dev/null || echo 0)"
			total=$((total + ${n:-0}))
		done < <(docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='${db}';" 2>/dev/null)
	done
	note "mysql: re-stamped rows in ${MYSQL_DBS}"
}

mongo_args() {
	local u p
	u="$(docker inspect "${MONGO_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MONGO_INITDB_ROOT_USERNAME=//p' | head -1)"
	p="$(docker inspect "${MONGO_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MONGO_INITDB_ROOT_PASSWORD=//p' | head -1)"
	printf '%s\n%s\n' "${u}" "${p}"
}

restamp_mongo() {
	local want="$1" db u p out
	running "${MONGO_CTN}" || { note "mongo not running — skipped"; return; }
	{ read -r u; read -r p; } < <(mongo_args)
	for db in ${MONGO_DBS}; do
		out="$(docker exec "${MONGO_CTN}" mongosh --quiet -u "${u}" -p "${p}" \
			--authenticationDatabase admin --eval "
				const d = db.getSiblingDB('${db}');
				let n = 0;
				d.getCollectionNames().forEach(c => {
					n += d[c].updateMany(
						{ owner_id: { \$regex: '^api-key:', \$ne: '${want}' } },
						{ \$set: { owner_id: '${want}' } }
					).modifiedCount;
				});
				print(n);
			" 2>/dev/null | tail -1)"
		note "mongo ${db}: re-stamped ${out:-0} documents"
	done
}

# ── env emission ────────────────────────────────────────────────────────────
# Rewrite KEY=VALUE in place (or append), preserving the file's mode. Never
# echoes the value.
put_env() {
	local file="$1" name="$2" value="$3"
	[ -f "${file}" ] || { install -m 600 /dev/null "${file}"; }
	python3 - "${file}" "${name}" "${value}" <<'PY'
import os, pathlib, sys
path, name, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
mode = os.stat(path).st_mode & 0o777 if path.exists() else 0o600
lines = path.read_text().splitlines() if path.exists() else []
out, seen = [], False
for line in lines:
    if line.split('=', 1)[0].strip() == name and not line.lstrip().startswith('#'):
        if not seen:
            out.append(f'{name}={value}')
            seen = True
        continue
    out.append(line)
if not seen:
    out.append(f'{name}={value}')
path.write_text('\n'.join(out) + '\n')
os.chmod(path, mode)
PY
}

main() {
	command -v docker >/dev/null 2>&1 || die "docker is required"
	command -v python3 >/dev/null 2>&1 || die "python3 is required"
	running "${TC_CTN}" || { note "${TC_CTN} not running — backend is down, skipping"; exit 0; }
	load_service_auth

	local key key_id stale
	key="$(read_key_from_env "${ENV_LOCAL}" OSIONOS_BAAS_API_KEY || true)"
	key_id=""
	if [ -n "${key}" ]; then
		key_id="$(verify_key "${key}" || true)"
	fi

	if [ -n "${key_id}" ]; then
		stale="$(stale_pg "api-key:${key_id}")"
		if [ "${stale:-0}" -eq 0 ]; then
			note "converged — key ${key_id} valid, demo rows already owned by it"
			exit 0
		fi
		note "key ${key_id} is valid but ${stale} rows carry a STALE principal"
	else
		note "no usable OSIONOS_BAAS_API_KEY in ${ENV_LOCAL}"
	fi

	if [ "${CHECK_ONLY}" -eq 1 ]; then
		note "repair needed — run: make live-data-ensure"
		exit 1
	fi

	if [ -z "${key_id}" ]; then
		note "issuing a new API key for tenant '${TENANT}'…"
		local body resp
		body='{"name":"osionos-app","scopes":["read","write"]}'
		svc_auth POST "/v1/tenants/${TENANT}/keys" "${body}"
		resp="$(curl -s --max-time 15 -X POST "${TC_URL}/v1/tenants/${TENANT}/keys" \
			-H 'Content-Type: application/json' "${SVC_AUTH[@]}" -d "${body}")"
		key="$(printf '%s' "${resp}" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')"
		key_id="$(printf '%s' "${resp}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
		if [ -z "${key}" ] || [ -z "${key_id}" ]; then die "key issue failed: ${resp}"; fi
		note "issued key ${key_id} (prefix $(printf '%s' "${key}" | cut -d_ -f2))"
	fi

	local principal="api-key:${key_id}"
	note "re-stamping demo data onto ${principal}"
	restamp_pg "${principal}"
	restamp_mysql "${principal}"
	restamp_mongo "${principal}"

	put_env "${ENV_LOCAL}" OSIONOS_BAAS_API_KEY "${key}"
	put_env "${APP_ENV}"   VITE_BAAS_API_KEY    "${key}"
	put_env "${APP_ENV}"   VITE_BAAS_TENANT_ID  "${TENANT}"
	note "wrote the key into ${ENV_LOCAL} and ${APP_ENV}"
	note "restart the bridge to pick it up:  docker compose up -d osionos-bridge"
}

main "$@"
