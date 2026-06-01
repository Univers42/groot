#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m2-federation.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 23:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 23:30:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M2 (real federation). Verifies:
#   - 3 new engines (mysql / redis / http) registered with query-router
#   - migration 014 applied (engine CHECK constraint accepts 'http')
#   - Trino catalogs mysql + iceberg present in conf
#   - Compose declares mysql + iceberg-rest services
#   - SDK codegen pipeline present (scripts + deps)
#
# Live mode (--live) additionally probes the running stack:
#   - GET /engines returns the 5 engines
#   - Trino SHOW CATALOGS lists ≥ 4 catalogs
#   - Iceberg roundtrip CREATE TABLE → INSERT → SELECT count
#   - mysql-engine roundtrip insert + read via query-router
#
# Designed to run from repo root. cd's there regardless of caller cwd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red   "[M2] FAIL: $*"; exit 1; }
step()  { cyan  "[M2] ${*}"; }
pass()  { green "[M2] PASS: ${*}"; }

# ── 1) Three new engine files implementing IDatabaseAdapter ───────────────────
step "checking new engine modules"
for engine in mysql redis http; do
  f="${BAAS_DIR}/src/apps/query-router/src/engines/${engine}.engine.ts"
  [[ -f "$f" ]] || fail "missing ${f}"
  grep -q "implements IDatabaseAdapter" "$f" || fail "${f} does not implement IDatabaseAdapter"
  grep -q "capabilities()" "$f" || fail "${f} missing capabilities() method"
  grep -q "execute(" "$f"      || fail "${f} missing execute() method"
done
pass "mysql / redis / http engines present and conform to IDatabaseAdapter"

# ── 2) Engines registered in QueryService + introspection controller ──────────
step "checking engines registered with QueryService + /engines endpoint"
SERVICE_TS="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
for engine in MysqlEngine RedisEngine HttpEngine; do
  grep -q "${engine}" "${SERVICE_TS}" || fail "${engine} not wired in query.service.ts"
done
[[ -f "${BAAS_DIR}/src/apps/query-router/src/query/engines.controller.ts" ]] \
  || fail "engines.controller.ts missing"
pass "5 engines wired + introspection controller exposed"

# ── 3) Migration 014 file present ─────────────────────────────────────────────
step "checking 014_add_http_engine migration"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/014_add_http_engine.sql"
[[ -f "${MIG}" ]] || fail "missing ${MIG}"
grep -q "'http'" "${MIG}" || fail "${MIG} does not mention 'http' in CHECK constraint"
grep -q "version = 14" "${MIG}" || fail "${MIG} missing version 14 guard"
pass "014_add_http_engine migration is well-formed"

# ── 4) Trino catalogs present ─────────────────────────────────────────────────
step "checking Trino catalogs"
for catalog in mysql iceberg; do
  f="${BAAS_DIR}/docker/services/trino/conf/catalog/${catalog}.properties"
  [[ -f "$f" ]] || fail "missing Trino catalog ${f}"
  grep -q "connector.name=${catalog}" "$f" || fail "${f} has wrong connector.name"
done
pass "mysql + iceberg Trino catalogs declared"

# ── 5) Compose services for mysql + iceberg-rest ──────────────────────────────
step "checking docker-compose declarations"
for service in "^  mysql:" "^  iceberg-rest:" "^  minio-iceberg-init:"; do
  grep -qE "${service}" "${COMPOSE_FILE}" \
    || fail "compose missing service ${service//\^  /}"
done
grep -qE "mysql.properties:/etc/trino/catalog/mysql.properties" "${COMPOSE_FILE}" \
  || fail "compose does not mount mysql.properties into trino"
grep -qE "iceberg.properties:/etc/trino/catalog/iceberg.properties" "${COMPOSE_FILE}" \
  || fail "compose does not mount iceberg.properties into trino"
pass "mysql + iceberg-rest + minio-iceberg-init declared & trino mounts updated"

# ── 6) SDK codegen pipeline ───────────────────────────────────────────────────
step "checking SDK codegen pipeline"
[[ -x "${BAAS_DIR}/scripts/openapi-collect.sh" ]] || fail "openapi-collect.sh missing or not executable"
[[ -f apps/baas/sdk/scripts/codegen.mjs ]] || fail "codegen.mjs missing"
grep -q '"codegen"'              apps/baas/sdk/package.json || fail "SDK package.json missing codegen script"
grep -q 'openapi-typescript-codegen' apps/baas/sdk/package.json || fail "SDK package.json missing openapi-typescript-codegen dep"
pass "openapi-collect + codegen + dep present"

# ── 7) Live probes (only with --live) ─────────────────────────────────────────
LIVE=0
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

if [[ ${LIVE} -eq 1 ]]; then
  M2_USER_ID="${M2_USER_ID:-00000000-0000-4000-8000-000000000002}"
  M3_USER_ID="${M3_USER_ID:-00000000-0000-4000-8000-000000000003}"

  step "live: /engines lists the 5 adapters"
  if ! command -v jq >/dev/null 2>&1; then
    red "jq is required for --live mode"; exit 2
  fi
  body=$(docker compose -f "${COMPOSE_FILE}" exec -T query-router node -e "fetch('http://127.0.0.1:4001/engines').then(async (r) => { if (!r.ok) process.exit(1); console.log(await r.text()); }).catch(() => process.exit(1));") \
    || fail "GET /engines inside query-router failed"
  for e in postgresql mongodb mysql redis http; do
    echo "${body}" | jq -e --arg e "$e" '.engines | index($e)' >/dev/null \
      || fail "engine '$e' not advertised by /engines"
  done
  pass "/engines advertises postgresql, mongodb, mysql, redis, http"

  step "live: migration 014 applied"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT 1 FROM public.schema_migrations WHERE version = 14" \
    | grep -q 1 || fail "migration 014 was not applied"
  pass "014_add_http_engine present in schema_migrations"

  step "live: ABAC permission schema and verifier roles ready"
  PERMISSIONS_MIG="${BAAS_DIR}/scripts/migrations/postgresql/007_permissions_system.sql"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 -f - < "${PERMISSIONS_MIG}" \
    >/dev/null || fail "permission migration 007 could not be applied"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 -f - >/dev/null <<'SQL'
CREATE OR REPLACE FUNCTION public.has_permission(
  p_user_id UUID,
  p_resource_type TEXT,
  p_resource_name TEXT,
  p_action TEXT
) RETURNS BOOLEAN AS $fn$
DECLARE
  policy_row RECORD;
  found BOOLEAN := false;
BEGIN
  FOR policy_row IN
    SELECT rp.effect, rp.conditions
    FROM public.resource_policies rp
    JOIN public.user_roles ur ON ur.role_id = rp.role_id
    WHERE ur.user_id = p_user_id
      AND (ur.expires_at IS NULL OR ur.expires_at > now())
      AND (rp.resource_type = p_resource_type OR rp.resource_type = '*')
      AND (rp.resource_name = p_resource_name OR rp.resource_name = '*')
      AND p_action = ANY(rp.actions)
    ORDER BY rp.priority DESC, rp.effect ASC
  LOOP
    IF policy_row.effect = 'deny' THEN
      RETURN false;
    END IF;
    found := true;
  END LOOP;

  RETURN found;
END;
$fn$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
SQL
  for abac_user_id in "${M2_USER_ID}" "${M3_USER_ID}"; do
    [[ "${abac_user_id}" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "invalid verifier user id ${abac_user_id}"
    docker compose -f "${COMPOSE_FILE}" exec -T postgres \
      psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 -v verifier_user_id="${abac_user_id}" -f - >/dev/null <<'SQL'
INSERT INTO public.user_roles (user_id, role_id)
SELECT :'verifier_user_id'::uuid, r.id
FROM public.roles r
WHERE r.name = 'user'
ON CONFLICT (user_id, role_id) DO NOTHING;
SQL
  done
  pass "ABAC permission schema applied and verifier users granted default role"

  step "live: Trino sees ≥ 4 catalogs including mysql + iceberg"
  catalogs=$(docker compose -f "${COMPOSE_FILE}" exec -T trino \
    trino --execute "SHOW CATALOGS" 2>/dev/null \
    | tr -d '"' | tr -d ' ' | grep -E '^(postgresql|mongodb|mysql|iceberg|system)$' || true)
  count=$(echo "${catalogs}" | grep -cE '^(postgresql|mongodb|mysql|iceberg)$' || true)
  [[ ${count} -ge 4 ]] || fail "Trino lists ${count} target catalogs, expected ≥ 4"
  pass "Trino SHOW CATALOGS includes postgresql, mongodb, mysql, iceberg"

  step "live: Iceberg roundtrip CREATE + INSERT + SELECT"
  docker compose -f "${COMPOSE_FILE}" exec -T trino \
    trino --execute "DROP TABLE IF EXISTS iceberg.default.m2_probe" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" exec -T trino trino --execute \
    "CREATE SCHEMA IF NOT EXISTS iceberg.default;
     CREATE TABLE iceberg.default.m2_probe (id int, v varchar);
     INSERT INTO iceberg.default.m2_probe VALUES (1, 'm2');
     SELECT count(*) FROM iceberg.default.m2_probe;" 2>/dev/null \
    | tail -1 | tr -d '"' | tr -d ' ' | grep -q '^1$' \
    || fail "Iceberg roundtrip via Trino did not return rowCount=1"
  pass "Iceberg roundtrip via Trino succeeded"

  step "live: MySQL adapter insert + read via query-router"
  docker compose -f "${COMPOSE_FILE}" exec -T mysql sh -s <<'SH'
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  owner_id VARCHAR(64) NOT NULL,
  name VARCHAR(128) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX users_owner_name_idx (owner_id, name)
);
SQL
SH
  mysql_dsn=$(docker compose -f "${COMPOSE_FILE}" exec -T mysql sh -c 'printf "mysql://%s:%s@mysql:3306/%s\n" "${MYSQL_USER}" "${MYSQL_PASSWORD}" "${MYSQL_DATABASE}"') \
    || fail "could not derive MySQL DSN from mysql service env"
  mysql_db_id=$(docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" -e M2_MYSQL_DSN="${mysql_dsn}" query-router node --input-type=module - <<'NODE'
const userId = process.env.M2_USER_ID;
const body = {
  engine: 'mysql',
  name: `m2-mysql-${Date.now()}`,
  connection_string: process.env.M2_MYSQL_DSN,
};
const response = await fetch('http://adapter-registry:3020/databases', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' },
  body: JSON.stringify(body),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
const json = await response.json();
console.log(json.id);
NODE
  ) || fail "could not register MySQL tenant database"
  docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" -e M2_DB_ID="${mysql_db_id}" query-router node --input-type=module - <<'NODE' \
    | jq -e '.rowCount >= 1' >/dev/null || fail "MySQL query-router roundtrip failed"
const userId = process.env.M2_USER_ID;
const dbId = process.env.M2_DB_ID;
const headers = { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' };
let response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/users`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'insert', data: { name: 'm2-probe' } }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/users`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'list', filter: { name: 'm2-probe' }, limit: 1 }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
console.log(await response.text());
NODE
  pass "MySQL adapter roundtrip succeeded"

  step "live: Redis adapter insert + read via query-router"
  redis_db_id=$(docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" query-router node --input-type=module - <<'NODE'
const userId = process.env.M2_USER_ID;
const body = {
  engine: 'redis',
  name: `m2-redis-${Date.now()}`,
  connection_string: 'redis://redis:6379',
};
const response = await fetch('http://adapter-registry:3020/databases', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' },
  body: JSON.stringify(body),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
const json = await response.json();
console.log(json.id);
NODE
  ) || fail "could not register Redis tenant database"
  docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" -e M2_DB_ID="${redis_db_id}" query-router node --input-type=module - <<'NODE' \
    | jq -e '.rowCount >= 1' >/dev/null || fail "Redis query-router roundtrip failed"
const userId = process.env.M2_USER_ID;
const dbId = process.env.M2_DB_ID;
const headers = { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' };
const id = `m2-${Date.now()}`;
let response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/m2_probe`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'insert', data: { id, name: 'm2-probe' } }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/m2_probe`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'get', filter: { id } }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
console.log(await response.text());
NODE
  pass "Redis adapter roundtrip succeeded"

  step "live: HTTP adapter write + read via query-router"
  http_db_id=$(docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" query-router node --input-type=module - <<'NODE'
const userId = process.env.M2_USER_ID;
const connection = {
  baseUrl: 'http://adapter-registry:3020',
  headers: { 'X-User-Id': userId, 'X-User-Role': 'authenticated' },
};
const body = {
  engine: 'http',
  name: `m2-http-${Date.now()}`,
  connection_string: JSON.stringify(connection),
};
const response = await fetch('http://adapter-registry:3020/databases', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' },
  body: JSON.stringify(body),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
const json = await response.json();
console.log(json.id);
NODE
  ) || fail "could not register HTTP tenant database"
  docker compose -f "${COMPOSE_FILE}" exec -T -e M2_USER_ID="${M2_USER_ID}" -e M2_DB_ID="${http_db_id}" query-router node --input-type=module - <<'NODE' \
    | jq -e '.rowCount >= 1' >/dev/null || fail "HTTP query-router roundtrip failed"
const userId = process.env.M2_USER_ID;
const dbId = process.env.M2_DB_ID;
const name = `m2-http-probe-${Date.now()}`;
const headers = { 'Content-Type': 'application/json', 'X-User-Id': userId, 'X-User-Role': 'authenticated' };
let response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/databases`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'insert', data: { engine: 'redis', name, connection_string: 'redis://redis:6379' } }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
response = await fetch(`http://127.0.0.1:4001/query/${dbId}/tables/databases`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ op: 'list', limit: 100 }),
});
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
const result = await response.json();
result.rowCount = Array.isArray(result.rows) && result.rows.some((row) => row.name === name) ? 1 : 0;
console.log(JSON.stringify(result));
NODE
  pass "HTTP adapter roundtrip succeeded"
fi

green "[M2] OK — all milestone-2 deliverables verified"
