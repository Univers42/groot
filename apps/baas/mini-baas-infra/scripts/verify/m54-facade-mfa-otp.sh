#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m54-facade-mfa-otp.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M54 — facade MFA→OTP completion, END TO END with a real emailed code (the
# residual the mfaId handshake left). binocle-one + Mailpit on a shared net:
#   1. auth-with-password on an MFA-enabled auth collection → 401 {mfaId};
#   2. request-otp → an 8-digit code is DELIVERED to Mailpit;
#   3. auth-with-otp {otpId, password: <emailed code>, mfaId} → a real token;
#   4. the issued token authenticates a subsequent records call.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M54] $*"; }
ok(){ green "  ✓ $*"; }
fail(){ red "[M54] FAIL — $*"; cleanup; exit 1; }

ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
NET="m54net"
PORT="${M54_PORT:-18997}"
MAILPIT_PORT="${M54_MAILPIT_PORT:-18998}"
BASE="http://127.0.0.1:${PORT}"
MAILPIT="http://127.0.0.1:${MAILPIT_PORT}"
SU_EMAIL="su@local.dev"
SU_PASS="m54-su-pass-12345"
USER_EMAIL="mfa-user@local.dev"
USER_PASS="m54-user-pass-12345"

cleanup(){
  docker rm -fv m54-one m54-mailpit >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker image inspect "${ONE_IMAGE}" >/dev/null 2>&1 || fail "build first: make one-build"
docker network create "${NET}" >/dev/null 2>&1 || true

step "boot Mailpit (SMTP sink) + binocle-one (SMTP → Mailpit)"
docker run -d --name m54-mailpit --network "${NET}" -p "${MAILPIT_PORT}:8025" \
  axllent/mailpit:latest >/dev/null
docker run -d --name m54-one --network "${NET}" -p "${PORT}:8090" \
  -e NANO_ADMIN_KEY="m54-$$" \
  -e ONE_SUPERUSER_EMAIL="${SU_EMAIL}" -e ONE_SUPERUSER_PASSWORD="${SU_PASS}" \
  -e ONE_SMTP_HOST=m54-mailpit -e ONE_SMTP_PORT=1025 -e ONE_SMTP_SECURITY=none \
  -e ONE_SMTP_FROM="binocle <no-reply@binocle.local>" \
  "${ONE_IMAGE}" >/dev/null
for i in $(seq 1 40); do
  curl -sf "${BASE}/api/health" >/dev/null 2>&1 \
    && curl -sf "${MAILPIT}/api/v1/info" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "boot timeout"
  sleep 0.25
done
ok "Mailpit + binocle-one up"

SU_TOKEN=$(curl -s -X POST "${BASE}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" -d "{\"identity\":\"${SU_EMAIL}\",\"password\":\"${SU_PASS}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

step "create an MFA+OTP auth collection + a verified user"
curl -s -X POST "${BASE}/api/collections" -H "Authorization: ${SU_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"mfausers","type":"auth","fields":[],
       "otp":{"enabled":true,"duration":300},
       "mfa":{"enabled":true,"duration":300},
       "listRule":"","viewRule":"","createRule":"","updateRule":"","deleteRule":""}' >/dev/null
RID=$(curl -s -X POST "${BASE}/api/collections/mfausers/records" -H "Content-Type: application/json" \
  -d "{\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"passwordConfirm\":\"${USER_PASS}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
[[ -n "${RID}" ]] || fail "could not register the MFA user"
ok "registered ${USER_EMAIL}"

step "first factor: auth-with-password → 401 {mfaId}"
PW_RESP=$(curl -s -o /tmp/m54-pw.json -w '%{http_code}' \
  -X POST "${BASE}/api/collections/mfausers/auth-with-password" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\"}")
[[ "${PW_RESP}" == "401" ]] || fail "expected 401 from MFA first factor, got ${PW_RESP}"
MFA_ID=$(python3 -c "import json;print(json.load(open('/tmp/m54-pw.json')).get('mfaId',''))")
[[ -n "${MFA_ID}" ]] || fail "no mfaId returned"
ok "mfaId issued: ${MFA_ID}"

step "second factor: request-otp → code DELIVERED to Mailpit"
OTP_ID=$(curl -s -X POST "${BASE}/api/collections/mfausers/request-otp" \
  -H "Content-Type: application/json" -d "{\"email\":\"${USER_EMAIL}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('otpId',''))")
[[ -n "${OTP_ID}" ]] || fail "no otpId returned"
CODE=""
for i in $(seq 1 20); do
  CODE=$(curl -s "${MAILPIT}/api/v1/search?query=$(python3 -c "import urllib.parse;print(urllib.parse.quote('to:'+'${USER_EMAIL}'))")" \
    | python3 -c "
import sys, json, re, urllib.request
d = json.load(sys.stdin)
msgs = d.get('messages', [])
if not msgs:
    print('')
else:
    mid = msgs[0]['ID']
    body = urllib.request.urlopen('${MAILPIT}/api/v1/message/' + mid).read().decode()
    m = re.search(r'\b(\d{8})\b', body)
    print(m.group(1) if m else '')
" 2>/dev/null || true)
  [[ -n "${CODE}" ]] && break
  sleep 0.5
done
[[ -n "${CODE}" ]] || fail "no 8-digit code delivered to Mailpit"
ok "code delivered: ${CODE}"

step "complete: auth-with-otp {otpId, code, mfaId} → real token"
AUTH=$(curl -s -X POST "${BASE}/api/collections/mfausers/auth-with-otp" \
  -H "Content-Type: application/json" \
  -d "{\"otpId\":\"${OTP_ID}\",\"password\":\"${CODE}\",\"mfaId\":\"${MFA_ID}\"}")
TOKEN=$(printf '%s' "${AUTH}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
[[ -n "${TOKEN}" ]] || fail "MFA OTP completion did not return a token: ${AUTH:0:200}"
ok "MFA OTP completed — token issued"

step "the issued token authenticates"
WHO=$(curl -s "${BASE}/api/collections/mfausers/records/${RID}" -H "Authorization: ${TOKEN}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('email',''))")
[[ "${WHO}" == "${USER_EMAIL}" ]] || fail "token did not authenticate (got '${WHO}')"
ok "token authenticates the record"

step "a stale/wrong mfaId is rejected"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/api/collections/mfausers/auth-with-otp" \
  -H "Content-Type: application/json" \
  -d "{\"otpId\":\"${OTP_ID}\",\"password\":\"${CODE}\",\"mfaId\":\"deadbeefdeadbee\"}")
[[ "${BAD}" == "400" ]] || fail "a wrong mfaId should 400 (got ${BAD})"
ok "wrong mfaId rejected"

green "[M54] PASS — facade MFA→OTP completes end-to-end with a real emailed code"
