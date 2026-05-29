# Backend hardening roadmap — mini-baas-infra

This folder tracks the plan to bring the seven backend dimensions of `mini-baas-infra` to a defensible 10/10 score for the RNCP CDA dossier, validated end-to-end by `make` targets that refuse to lie.

## The seven dimensions

| # | Dimension | Current | Target |
|---|---|---|---|
| a | Docker-first micro-services | 9/10 | 10/10 |
| b | Data federation | 6/10 | 10/10 |
| c | Cross-engine coherence | 4/10 | 10/10 |
| d | Unified API & client SDK | 6/10 | 10/10 |
| e | Security & observability | 7/10 | 10/10 |
| f | Dev & deployment tooling | 9/10 | 10/10 |
| g | Auditability & traceability | 5/10 | 10/10 |

## Milestone plan

Each milestone is **autonomous**, **idempotent**, and **gated by a single `make` target** that must return `0` for the milestone to count as done.

| ID | Targets | Deliverables | Make gate |
|---|---|---|---|
| [M1](./M1-hardening.md) | a, f, g (light) | `HEALTHCHECK` in every Dockerfile, `IDatabaseAdapter` contract, OpenAPI on the 9 NestJS services, `audit_log` migration, correlation-ID propagated into audit rows | `make baas-verify-m1` |
| [M2](./M2-federation.md) | b, d | `MysqlEngine`, `RedisEngine`, `HttpEngine`, Trino catalogs (`mysql`, `iceberg-on-minio`), unified `op`-based query DSL, SDK codegen from OpenAPI | `make baas-verify-m2` |
| [M3](./M3-coherence.md) | c, g | `outbox_events` migration, `outbox-relay` service (PG WAL → Redis Streams), idempotency middleware (`Idempotency-Key`), single RLS model (`current_setting('request.jwt.claims')`) | `make baas-verify-m3` |
| [M4](./M4-observability.md) | e, g | `prometheus` + `grafana` + `loki` + `promtail` + `tempo` services, `/metrics` on every NestJS app, OpenTelemetry SDK with correlation-ID → traces in Tempo, `log-service` shipping to Loki | `make baas-verify-m4` |
| [M5](./M5-security.md) | e | ModSecurity WAF in front of Kong, Kong rate-limit plugin, `helmet`/CSP defaults, automated JWT rotation via Vault, blocking SAST (Sonar) in CI | `make baas-verify-m5` |

## Verification spine (to add first)

The Makefile spine lives in [`infrastructure/makes/baas-verify.mk`](../../infrastructure/makes/) and chains the milestones cumulatively:

```make
.PHONY: baas-verify-m1 baas-verify-m2 baas-verify-m3 baas-verify-m4 baas-verify-m5 baas-verify-all

baas-verify-all: baas-verify-m1 baas-verify-m2 baas-verify-m3 baas-verify-m4 baas-verify-m5

baas-build: ; docker buildx bake --file docker-bake.hcl
baas-up:    ; docker compose -f apps/baas/mini-baas-infra/docker-compose.yml up -d --wait
baas-down:  ; docker compose -f apps/baas/mini-baas-infra/docker-compose.yml down -v

baas-verify-m1: baas-build baas-up
	@bash apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh

baas-verify-m2: baas-verify-m1
	@bash apps/baas/mini-baas-infra/scripts/verify/m2-federation.sh

baas-verify-m3: baas-verify-m2
	@bash apps/baas/mini-baas-infra/scripts/verify/m3-coherence.sh

baas-verify-m4: baas-verify-m3
	@bash apps/baas/mini-baas-infra/scripts/verify/m4-observability.sh

baas-verify-m5: baas-verify-m4
	@bash apps/baas/mini-baas-infra/scripts/verify/m5-security.sh
```

Every `mX-*.sh` runs with `set -euo pipefail` and exits non-zero on the first failed assertion, so CI cannot pass a half-broken milestone.

## Execution order rationale

1. **M1 first, always.** Without `IDatabaseAdapter` formalised, every new engine added in M2 duplicates the current pg/mongo divergence. Without OpenAPI, the SDK codegen in M2 has nothing to consume. Without `audit_log`, M3's outbox has no trace surface.
2. **M3 before M4.** Observability of fake coherence is misleading. We want traces and metrics to reflect a system that is *actually* consistent.
3. **M5 last.** Security hardening only makes sense once the surface area is stable. Tightening WAF rules around a moving target wastes time.

## RNCP defensibility note

For the dossier, **M1 + M3 + M4 are sufficient** to defend "10/10 across the seven dimensions". M2 and M5 are bonus. If time is short, prioritise the first three and document M2/M5 as `Perspectives d'évolution`.

## Status

| Milestone | Status | Started | Done | Gate green |
|---|---|---|---|---|
| M1 | not started | — | — | ❌ |
| M2 | not started | — | — | ❌ |
| M3 | not started | — | — | ❌ |
| M4 | not started | — | — | ❌ |
| M5 | not started | — | — | ❌ |

Update this table whenever a milestone ships.
