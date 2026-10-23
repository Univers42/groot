# 0007. WAF rule 10110 also lifts CRS 921130 on ARGS of osionos_* writes

- Status: accepted with conditions (nothing built or deployed yet)
- Date: 2026-10-17
- Deciders: devil (risk ruling of 2026-10-17). The user runs the b2b deploy.

## Context

- Every save of the object database "dylan-lessons" returned a WAF 403. Of the 8 states replayed, 7 got
  204 and dylan-lessons got 403. The audit entry 179225447561.373534 shows 921130 as the only scoring rule
  (score 5, threshold 5). It matched `HTTP/2 vs HTTP/3` in
  `ARGS:json.state.pages.dylan-lessons-r019.properties.dylan-lessons-title` (measured 2026-10-17).
- The bridge writes `osionos_object_databases?on_conflict=owner_id,db_key`
  (`apps/osionos/app/scripts/bridge-api.mjs:3279`). Rule 10110 matches that path and method, lifts only
  the injection families, and keeps the protocol rules
  (`apps/grobase/infra/docker/services/waf/conf/exclusions.conf:23-63`).
- In CRS 4.25.0, `REQUEST-921-PROTOCOL-ATTACK.conf` gives these targets:
  - 921130: `REQUEST_COOKIES|REQUEST_COOKIES_NAMES|ARGS_NAMES|ARGS|XML:/*` (line 99)
  - 921120: CR/LF followed by content-type, length, set-cookie or location, on ARGS (line 77)
  - 921110: request smuggling, unanchored, on `ARGS_NAMES|ARGS|REQUEST_BODY` (line 39)
- The image is published only on a push to grobase main (`apps/grobase/.github/workflows/ci.yml:342-345`).
- Unknown when this was written:
  - whether the image running on b2b (sha256:698af2fe…) contains 10110 or the later rules;
  - whether PostgREST v12.2.3 percent-encodes primary-key values in `Location`;
  - the VM's effective paranoia level.

## Decision

On POST, PATCH and PUT to `^/rest/v1/osionos_[a-z_]+$`, 921130 no longer inspects ARGS. All other
protocol rules keep inspecting those requests, including 921110 and 921120. 921130 also stays on cookies,
argument names and every other path. Content that trips 921110 (e.g. `GET /index.html HTTP/1.1`) or
921120 (multi-line `Content-Type: x`) is still refused on these writes, and m227 tests that as a boundary.

## Alternatives considered

- **Lift the whole `attack-protocol` tag on these writes**: it also drops 921120 and 921150, the CR/LF
  checks that splitting and header injection actually need. That is wider than the one measured hit
  justifies.
- **Also lift 921110**: it reads `REQUEST_BODY`, so an ARGS removal does not reach it. Lifting it there
  stops body inspection for request smuggling on the public edge. That is a separate decision, to be made
  on its own measured hit.
- **Do nothing; users rename their titles**: every HTTP-themed title stays unsaveable server-side. The
  data survives only in localStorage, so devices diverge.

## Consequences

The devil's conditions W1-W9 are the acceptance criteria. They are in
`/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-waf-921130-2026-10-17.md`:

- a one-line scope;
- a comment with the verifiable safety argument and the boundaries it keeps;
- positive and negative probes in m227 with a line-level mutant;
- a gate run on a locally built image (also at PL2), together with m198 and m207;
- a replay of all 8 real states before merge;
- U1 closed by diffing the running exclusions file before deploy;
- a sha-pinned deploy with a rollback tag.

Rpc writes carrying user text (`rpc/osionos_bridge_upsert_workspace`, `bridge-api.mjs:1240`) are still
inspected in full. Reverse by reverting the line and redeploying the rollback tag.

Amendment of 2026-10-17 (expedited deploy before the merge, ruled PROCEED-WITH-CONDITIONS). b2b may run
the host image that m227 and the 8-state replay tested before the merge. It runs under a local
`grobase-waf:fix-921130-a42a8077` tag that shadows `:latest`:
- The image is never rebuilt on the VM. `waf/Dockerfile:12` runs `apt-get upgrade`, so a rebuild is not
  the image that was tested.
- Nothing runs git in `/opt/grobase`, which the mail runbook owns.
- Identity is proven by `RootFS.Layers`.

The rejected alternative was building from a worktree of `/opt/grobase`. It produces an untested image,
needs a Docker Hub pull, and shares a `FETCH_HEAD` with the mail runbook. The shadow is retired once CI
publishes `:sha-<merge>`. Conditions X1-X2, P0, S1-S6, A1-A4, M1-M4 and R1-R8 are in the "Addendum:
expedite before merge" section of the verdict file.
