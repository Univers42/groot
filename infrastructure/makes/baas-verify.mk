# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    baas-verify.mk                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 22:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Milestone-gated verification targets for the mini-baas backend.
#
# Each `baas-verify-mX` target wraps the matching script under
# apps/baas/mini-baas-infra/scripts/verify/. The script is the single source
# of truth — Make targets are thin wrappers so CI and humans use the same
# entrypoints.
#
# Static gate (default):
#   make baas-verify-m1
#
# Full gate (requires the stack to be up via `make baas-up`):
#   BAAS_VERIFY_LIVE=1 make baas-verify-m1

BAAS_VERIFY_DIR := apps/baas/mini-baas-infra/scripts/verify
BAAS_COMPOSE_FILE := apps/baas/mini-baas-infra/docker-compose.yml

# Set BAAS_VERIFY_LIVE=1 to enable runtime probes (docker compose health,
# /docs-json HTTP curl, audit_log row count).
BAAS_VERIFY_LIVE ?=
BAAS_VERIFY_FLAGS := $(if $(BAAS_VERIFY_LIVE),--live,)

# Set BAAS_VERIFY_SAFE_PORTS=1 to remap every host port to a high port
# (15000+) so the stack never collides with another local DB / service.
# Container-to-container traffic stays on the internal docker network and is
# untouched.
BAAS_VERIFY_SAFE_PORTS ?=
ifdef BAAS_VERIFY_SAFE_PORTS
  BAAS_PORT_OVERRIDES := \
    PG_PORT=15432 \
    MONGO_PORT=27018 \
    REDIS_PORT=16379 \
    VAULT_PORT=18200 \
    KONG_HTTP_PORT=18000 \
    KONG_ADMIN_PORT=18001 \
    WAF_HTTP_PORT=18880 \
	WAF_HTTPS_PORT=18443 \
    MINIO_API_PORT=19000 \
	MINIO_CONSOLE_PORT=19011 \
	PROMETHEUS_PORT=19090 \
	GRAFANA_PORT=13030 \
	LOKI_PORT=13100 \
	PROMTAIL_PORT=19080 \
	TEMPO_PORT=13200 \
	OTEL_COLLECTOR_HTTP_PORT=14318 \
	OTEL_COLLECTOR_GRPC_PORT=14317 \
	OTEL_COLLECTOR_HEALTH_PORT=13133
endif

# Set BAAS_VERIFY_NO_WAF=1 to scale the WAF container down to zero. Use this
# when only the BaaS gateway + microservices are needed (M1 / M2 verify scripts
# probe Kong & NestJS apps directly on the docker network; WAF is irrelevant
# for them, and its OWASP-CRS base image has a known entrypoint perms issue).
BAAS_VERIFY_NO_WAF ?=
BAAS_VERIFY_SCALE := $(if $(BAAS_VERIFY_NO_WAF),--scale waf=0,)

# Profiles needed to expose every NestJS app the M1 verify probes. Skip
# `observability` (Prometheus/Grafana/Loki) and `analytics` (Trino) to keep
# the smoke set lean. Set BAAS_VERIFY_FULL=1 to also include them.
BAAS_VERIFY_FULL ?=
BAAS_VERIFY_OBSERVABILITY ?=
BAAS_VERIFY_PROFILES := \
  --profile control-plane \
  --profile adapter-plane \
  --profile data-plane \
  --profile background \
  --profile storage \
	$(if $(or $(BAAS_VERIFY_FULL),$(BAAS_VERIFY_OBSERVABILITY)),--profile observability,) \
	$(if $(BAAS_VERIFY_FULL),--profile analytics --profile extras,)

BAAS_COMPOSE_FILES := -f $(BAAS_COMPOSE_FILE)

.PHONY: baas-verify-m1 baas-verify-m2 baas-verify-m3 baas-verify-m4 baas-verify-m5 baas-verify-m6 baas-verify-m7 baas-verify-m8 baas-verify-m9 baas-verify-m10 baas-verify-all baas-up baas-down

baas-up:
## Bring the baas docker-compose stack up and wait for healthchecks.
	@set -e; \
	bash apps/baas/scripts/generate-localhost-cert.sh >/dev/null; \
	if $(BAAS_PORT_OVERRIDES) docker compose $(BAAS_COMPOSE_FILES) $(BAAS_VERIFY_PROFILES) up -d --wait $(BAAS_VERIFY_SCALE); then \
		:; \
	else \
		status=$$?; \
		if $(BAAS_PORT_OVERRIDES) docker compose $(BAAS_COMPOSE_FILES) $(BAAS_VERIFY_PROFILES) ps --all --format json | jq -e 'def row: if type == "array" then .[] elif type == "object" then . elif type == "string" then (try fromjson catch empty) | row else empty end; def expected_job: (.Service // (.Name // "" | sub("^mini-baas-"; ""))) as $$service | (["db-bootstrap", "mongo-keyfile", "mongo-init", "vault-init", "minio-iceberg-init"] | index($$service)) != null and ((.State // "") == "exited") and (((.ExitCode // 0) | tonumber?) // 0) == 0; [ row | select(expected_job | not) | select((.State // "") == "created" or (.State // "") == "exited" or (.Health // "") == "unhealthy" or (.Health // "") == "starting") ] | length == 0' >/dev/null; then \
			echo "baas-up: stack healthy; expected init jobs exited 0"; \
		else \
			exit $$status; \
		fi; \
	fi

baas-down:
## Stop the baas stack and remove its volumes.
	$(BAAS_PORT_OVERRIDES) docker compose $(BAAS_COMPOSE_FILES) $(BAAS_VERIFY_PROFILES) down -v

baas-verify-m1:
## Verify M1 hardening deliverables (HEALTHCHECK, IDatabaseAdapter, OpenAPI, audit_log).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m1-hardening.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m2: baas-verify-m1
## Verify M2 federation deliverables (mysql/redis/http engines, Trino catalogs, SDK codegen).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m2-federation.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m3: baas-verify-m2
## Verify M3 coherence deliverables (outbox, unified RLS, idempotency, relay projection).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m3-coherence.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m4: baas-verify-m3
## Verify M4 observability deliverables (metrics, traces, Loki, dashboards, alerts).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m4-observability.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m5: baas-verify-m4
## Verify M5 security deliverables (WAF, Kong plugins, headers, rotation, scanner hooks).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m5-security.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m6: baas-verify-m5
## Verify M6 FDW universal gateway deliverables.
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m6-fdw.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m7: baas-verify-m6
## Verify M7 expanded adapter deliverables.
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m7-adapters.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m8: baas-verify-m7
## Verify M8 outbox/debezium/saga deliverables.
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m8-saga.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m9: baas-verify-m8
## Verify M9 centralized ABAC deliverables.
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m9-abac.sh $(BAAS_VERIFY_FLAGS)

baas-verify-m10: baas-verify-m9
## Verify M10 SDK capabilities-at-type-level deliverables.
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m10-sdk.sh $(BAAS_VERIFY_FLAGS)

baas-verify-all: baas-verify-m10
## Run every milestone gate currently shipped.
	@echo "[baas-verify] M1 + M2 + M3 + M4 + M5 + M6 + M7 + M8 + M9 + M10 OK."

# ── Security scanner suite (Docker-only) ──────────────────────────────────────
# Runs Semgrep (SAST) + npm/pnpm audit (SCA) + Trivy (containers + fs) +
# TruffleHog (secrets) sequentially. Each tool runs in its official Docker
# image so the host needs nothing more than `docker`.
#
#   make baas-security-scan                       # all enabled scanners
#   make baas-security-scan SECURITY_ONLY=trivy   # only Trivy
#   make baas-security-scan SECURITY_SKIP=trufflehog
SECURITY_ONLY ?=
SECURITY_SKIP ?=
SECURITY_FAIL_LEVEL ?= high
SECURITY_TRIVY_SEVERITY ?= HIGH,CRITICAL

.PHONY: baas-security-scan baas-zap

baas-security-scan:
## SAST + SCA + Container + Secret scan via Docker (no host install required).
	@SECURITY_FAIL_LEVEL=$(SECURITY_FAIL_LEVEL) \
	 SECURITY_TRIVY_SEVERITY=$(SECURITY_TRIVY_SEVERITY) \
	 bash apps/baas/mini-baas-infra/scripts/security/run-security-scans.sh \
	   $(if $(SECURITY_ONLY),--only=$(SECURITY_ONLY),) \
	   $(if $(SECURITY_SKIP),--skip=$(SECURITY_SKIP),)

baas-zap:
## DAST baseline scan with OWASP ZAP against the live WAF. Stack must be up.
## Usage: BAAS_VERIFY_SAFE_PORTS=1 make baas-zap
	@WAF_HTTPS_PORT=$${WAF_HTTPS_PORT:-18443} \
	 bash apps/baas/mini-baas-infra/scripts/verify/zap-baseline.sh

# ── SDK codegen (Docker-only, no node required on host) ───────────────────────
BAAS_CODEGEN_IMAGE := mini-baas-sdk-codegen:local
BAAS_CODEGEN_NETWORK := mini-baas_mini-baas

.PHONY: baas-codegen-image baas-codegen

baas-codegen-image:
## Build the one-shot image that runs openapi-collect + codegen inside docker.
	docker build -f apps/baas/sdk/Dockerfile.codegen -t $(BAAS_CODEGEN_IMAGE) apps/baas/sdk

baas-codegen: baas-codegen-image
## Collect /docs-json from running NestJS apps and generate typed SDK clients.
## Reuses the mini-baas docker network so it can reach services without host port mappings.
	docker run --rm \
	  --network $(BAAS_CODEGEN_NETWORK) \
	  -v $(CURDIR):/work \
	  -w /work \
	  -e OPENAPI_BASE_URL=http://host.docker.internal:0 \
	  --add-host host.docker.internal:host-gateway \
	  $(BAAS_CODEGEN_IMAGE) \
	  'bash apps/baas/mini-baas-infra/scripts/openapi-collect.sh --docker-network && \
	   cd apps/baas/sdk && \
	   npm install --no-audit --no-fund --prefer-offline && \
	   node ./scripts/codegen.mjs'
