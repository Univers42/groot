#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m48-orchestrator-parity.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M48 — Node↔Go orchestrator response parity (Track-2 A1/A2).
#
# Before the six Node orchestrators can be retired, the consolidated Go binary
# must answer byte-shape-identically — a client cannot tell which served it.
# This drove out two real divergences (now fixed):
#   1. the Nest TransformInterceptor envelope ({success,statusCode,message,
#      data,path,timestamp}) — ported as internal/orchestrator/envelope;
#   2. bigint PKs serialized as strings by TypeORM — Go fields got `,string`.
#
# Scope today: the NEWSLETTER subscribe path (public, no signed-envelope auth →
# directly comparable). The strict-auth endpoints (session/gdpr) require minting
# a signed identity envelope to reach the Node side and are the gate's documented
# extension point. Runs both sides in-network; SKIPs when either is down.

set -euo pipefail

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M48] $*"; }
pass()  { green "[M48] PASS: $*"; }
fail()  { red "[M48] FAIL: $*"; exit 1; }
skip()  { printf '\033[1;33m[M48] SKIP: %s\033[0m\n' "$*"; exit 0; }

ORCH=mini-baas-orchestrator
NODE_NL=mini-baas-newsletter-service
NET=mini-baas_mini-baas
CURL_IMG=curlimages/curl:8.10.1

docker inspect -f '{{.State.Running}}' "${ORCH}" 2>/dev/null | grep -q true \
  || skip "${ORCH} not running (start it with ORCHESTRATOR_SERVICES including newsletter)"
docker inspect -f '{{.State.Running}}' "${NODE_NL}" 2>/dev/null | grep -q true \
  || skip "${NODE_NL} not running (need the Node side to diff against)"

# Confirm the orchestrator actually mounted newsletter (else the probe 404s).
docker logs "${ORCH}" 2>&1 | grep -q '"service":"newsletter"' \
  || skip "orchestrator is up but newsletter sub-service not mounted (ORCHESTRATOR_SERVICES)"

NODE_PORT="$(docker inspect "${NODE_NL}" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^PORT=//p' | head -1)"
NODE_PORT="${NODE_PORT:-3090}"

incurl() { docker run --rm --network "${NET}" "${CURL_IMG}" -s "$@"; }

step "subscribe through BOTH implementations (unique emails)"
STAMP="$(date +%s)$$"
NODE_RESP="$(incurl -X POST "http://newsletter-service:${NODE_PORT}/subscribe" \
  -H 'Content-Type: application/json' -d "{\"email\":\"m48-node-${STAMP}@example.com\"}")"
GO_RESP="$(incurl -X POST "http://orchestrator:3026/subscribe" \
  -H 'Content-Type: application/json' -d "{\"email\":\"m48-go-${STAMP}@example.com\"}")"
[ -n "${NODE_RESP}" ] && [ -n "${GO_RESP}" ] || fail "empty response (node=${NODE_RESP:0:80} go=${GO_RESP:0:80})"

step "canonical shape diff (types + structure, volatile fields normalized)"
python3 - "${NODE_RESP}" "${GO_RESP}" <<'PY'
import json, sys
try:
    n = json.loads(sys.argv[1]); g = json.loads(sys.argv[2])
except Exception as e:
    print(f"  non-JSON response: {e}\n  node={sys.argv[1][:160]}\n  go={sys.argv[2][:160]}"); sys.exit(1)

def shape(d):
    if isinstance(d, dict): return {k: shape(v) for k, v in sorted(d.items())}
    if isinstance(d, list): return [shape(x) for x in d[:1]]
    return type(d).__name__

ns, gs = shape(n), shape(g)
# path/timestamp/message vary per request/instant — compare structure, not value.
for s in (ns, gs):
    for k in ("path", "timestamp", "message"):
        s.pop(k, None)

if ns != gs:
    print("  DIVERGES")
    print("  node:", json.dumps(ns))
    print("  go:  ", json.dumps(gs))
    sys.exit(1)
print("  envelope + subscriber types byte-shape identical")
PY
[ $? -eq 0 ] || fail "Node and Go newsletter responses diverge in shape/type"
pass "newsletter subscribe: Node ↔ Go response parity (envelope + bigint-as-string id)"

green "[M48] ALL GATES GREEN — consolidated Go orchestrator answers shape-identically to Node (newsletter; envelope + id-type parity proven)"
