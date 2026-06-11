#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m33-lean-basic.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for the LEAN BASIC tier (Phase C) — the Pi-class, Node-free shape.
#
#   1. Footprint: PACKAGE=basic fits ≤512 MiB (the $5-VPS / Pi bar).
#   2. Node-free CRUD: an insert + read round-trip through the Rust `/data/v1`
#      bypass — Kong→Rust→engine + Go tenant-control/adapter-registry, with NO
#      query-router / permission-engine in the path (the Node services basic
#      omits). Engine = postgresql (a basic-tier engine); the table is created
#      out-of-band (DDL is a migration concern, not a request-path one — the
#      bypass intentionally exposes only data ops).
#   3. Scope gate: a read-only key is DENIED a write (403) but allowed a read —
#      the api-key authorization a Node-free tier depends on (Phase C1).
#
set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
fail(){ red "[M33] FAIL: $*"; exit 1; }
step(){ cyan "[M33] ${*}"; }
pass(){ green "[M33] PASS: ${*}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-live-tenant.sh"

RUST_PORT="$(docker port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
RUST="http://127.0.0.1:${RUST_PORT:-4011}"
DATA="${RUST}/data/v1/query"

# ── 1. footprint ──────────────────────────────────────────────────────────
step "footprint: PACKAGE=basic must fit ≤512 MiB"
PROFILES="go-control-plane rust-data-plane" LABEL="basic" BAR_MB=512 \
  bash "${SCRIPT_DIR}/../bench/footprint.sh" >/tmp/m33-fp.txt 2>&1 \
  || { cat /tmp/m33-fp.txt; fail "basic tier exceeds its 512 MiB budget"; }
grep -E 'TOTAL|budget' /tmp/m33-fp.txt
pass "basic tier within the Pi-class budget"

# ── provision a probe tenant + read+write key + pg mount (Go control plane) ─
step "provisioning a probe tenant + key + mount (Node-free Go control plane)"
live_tenant_provision "basic-$(date +%s)" || fail "provision failed"
trap live_tenant_cleanup EXIT
DBID="${LIVE_TENANT_DB_ID}"
WKEY="${LIVE_TENANT_API_KEY}"   # read+write

# scratch table in the probe's postgres (operator/migration step, out-of-band).
PGUSER="$(_lt_env mini-baas-postgres POSTGRES_USER)"; PGUSER="${PGUSER:-postgres}"
PGPASS="$(_lt_env mini-baas-postgres POSTGRES_PASSWORD)"; PGPASS="${PGPASS:-postgres}"
PGDB="$(_lt_env mini-baas-postgres POSTGRES_DB)"; PGDB="${PGDB:-postgres}"
docker exec -e PGPASSWORD="${PGPASS}" mini-baas-postgres \
  psql -U "${PGUSER}" -d "${PGDB}" -v ON_ERROR_STOP=1 -c \
  'CREATE TABLE IF NOT EXISTS lean_probe (id text PRIMARY KEY, owner_id text, name text)' >/dev/null \
  || fail "could not create the scratch table"

post_data() { # $1 key  $2 json-body  → echoes "HTTP <code> <body>"
  curl -s -w ' HTTP%{http_code}' -X POST "${DATA}" \
    -H "X-Baas-Api-Key: $1" -H 'Content-Type: application/json' -d "$2"
}

# ── 2. Node-free CRUD through /data/v1 with the read+write key ──────────────
step "write+read through /data/v1 (no query-router in the path)"
INS="$(post_data "${WKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"lean_probe\",\"data\":{\"id\":\"p1\",\"name\":\"lean-hello\"}}}")"
echo "${INS}" | grep -q 'HTTP20[01]' || fail "insert via /data/v1 did not succeed: ${INS}"
LST="$(post_data "${WKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"list\",\"resource\":\"lean_probe\",\"limit\":10}}")"
echo "${LST}" | grep -q 'lean-hello' || fail "read-back via /data/v1 missing the row: ${LST}"
pass "insert + read round-trip clean through the Node-free bypass"

# ── 3. scope gate: a read-only key is denied the write, allowed the read ────
step "scope gate: read-only key → write 403, read 200 (Phase C1)"
code=$(curl -s -o /tmp/m33-rk.json -w '%{http_code}' -X POST \
  "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${LIVE_TENANT_SLUG}/keys" \
  -H "X-Service-Token: ${LIVE_SERVICE_TOKEN}" -H 'Content-Type: application/json' \
  -d '{"name":"m33-readonly","scopes":["read"]}')
[[ "${code}" == "201" ]] || fail "read-only key mint failed (${code})"
RKEY="$(sed -n 's/.*"key":"\([^"]*\)".*/\1/p' /tmp/m33-rk.json | head -1)"
[[ "${RKEY}" == mbk_* ]] || fail "read-only key has unexpected shape"

WROTE="$(post_data "${RKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"lean_probe\",\"data\":{\"id\":\"p2\",\"name\":\"should-fail\"}}}")"
echo "${WROTE}" | grep -q 'HTTP403' || fail "read-only key was NOT denied the write: ${WROTE}"
READ="$(post_data "${RKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"list\",\"resource\":\"lean_probe\",\"limit\":1}}")"
echo "${READ}" | grep -q 'HTTP200' || fail "read-only key was denied a READ: ${READ}"
pass "scope gate enforced — write denied (403), read allowed (200)"

green "[M33] ALL GATES GREEN — basic tier is Pi-class (≤512 MiB), Node-free, and scope-enforced"
