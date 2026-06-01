#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M7] FAIL: $*"; exit 1; }
step()  { cyan "[M7] ${*}"; }
pass()  { green "[M7] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "checking M7 adapter files"
for engine in jdbc cassandra neo4j elasticsearch qdrant influx; do
  file="${BAAS_DIR}/src/apps/query-router/src/engines/${engine}.engine.ts"
  [[ -f "${file}" ]] || fail "missing ${file}"
  grep -q "implements IDatabaseAdapter" "${file}" || fail "${file} does not implement IDatabaseAdapter"
  grep -q "capabilities()" "${file}" || fail "${file} missing capabilities()"
  grep -q "execute(" "${file}" || fail "${file} missing execute()"
  grep -q "listResources(" "${file}" || fail "${file} missing listResources()"
done
pass "jdbc/cassandra/neo4j/elasticsearch/qdrant/influx adapters implement IDatabaseAdapter"

step "checking QueryModule providers and QueryService registry"
MODULE="${BAAS_DIR}/src/apps/query-router/src/query/query.module.ts"
SERVICE="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
for class in JdbcEngine CassandraEngine Neo4jEngine ElasticsearchEngine QdrantEngine InfluxEngine; do
  grep -q "${class}" "${MODULE}" || fail "${class} missing from QueryModule"
  grep -q "${class}" "${SERVICE}" || fail "${class} missing from QueryService"
done
for engine in jdbc cassandra neo4j elasticsearch qdrant influx; do
  grep -q "readonly engine = '${engine}'" "${BAAS_DIR}/src/apps/query-router/src/engines/${engine}.engine.ts" \
    || fail "${engine}.engine.ts has wrong engine id"
done
pass "M7 adapters are registered in the router"

step "checking tenant_databases engine constraint migration"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/021_extend_engine_check.sql"
[[ -f "${MIG}" ]] || fail "missing ${MIG}"
for engine in jdbc cassandra neo4j elasticsearch qdrant influx; do
  grep -q "'${engine}'" "${MIG}" || fail "021 migration missing ${engine}"
  grep -q "'${engine}'" "${BAAS_DIR}/src/apps/adapter-registry/src/databases/dto/register-database.dto.ts" \
    || fail "RegisterDatabaseDto missing ${engine}"
done
pass "database registry accepts M7 engine identifiers"

if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"

  step "live: /engines advertises at least 11 adapters"
  body=$(docker compose -f "${COMPOSE_FILE}" exec -T query-router \
    node -e "fetch('http://127.0.0.1:4001/engines').then(async (r) => { if (!r.ok) process.exit(1); console.log(await r.text()); }).catch(() => process.exit(1));") \
    || fail "GET /engines inside query-router failed"
  count=$(echo "${body}" | jq -r '.engines | length')
  [[ "${count}" -ge 11 ]] || fail "/engines returned ${count}, expected >= 11"
  for engine in postgresql mongodb mysql redis http jdbc cassandra neo4j elasticsearch qdrant influx; do
    echo "${body}" | jq -e --arg engine "${engine}" '.engines | index($engine)' >/dev/null \
      || fail "engine ${engine} not advertised"
  done
  pass "/engines advertises the M2 + M7 adapter set"
fi

green "[M7] OK — all milestone-7 deliverables verified"