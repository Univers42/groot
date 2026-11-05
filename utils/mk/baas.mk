# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    baas.mk                                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:57:54 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:57:55 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

##@ Tests
baas-smoke: ## Smoke-test the running BaaS gateway through the frontend verifier
	cd $(FRONTEND_DIR) && node scripts/verify-connection.mjs

OSIONOS_APP_ENV := apps/osionos/app/.env

##@ Backend (grobase)
seed-live-demo: ## Seed the live-database demo, then rebuild osionos-app with the BaaS env
## Seed the live-database demo (pg-commerce + mysql-ops + mongo-activity through the grobase control
## plane), then rebuild osionos-app with the BaaS env baked in and restart it. Needs the grobase
## stack up (make -C apps/grobase up).
	@$(MAKE) -C apps/grobase seed-live-demo APP_ENV_FILE=$(CURDIR)/apps/osionos/app/.env
	@$(MAKE) osionos-app-live

osionos-app-live: submodules-pinned ## Rebuild and restart osionos-app with the VITE_BAAS_* values from its .env
## Rebuild + restart osionos-app with the VITE_BAAS_* values from the app .env (vite inlines env at
## build time; the seeder writes the live-demo keys there). Two --env-file flags: the root .env
## keeps its port interpolations, the app .env supplies the VITE_BAAS_* build args (later files
## win).
	@test -f $(OSIONOS_APP_ENV) || { echo "missing $(OSIONOS_APP_ENV) — run make seed-live-demo first"; exit 1; }
	@touch .env
	$(WITH_GRAPH_RENDER_SHA) docker compose --env-file .env --env-file $(OSIONOS_APP_ENV) build osionos-app
	docker compose --env-file .env --env-file $(OSIONOS_APP_ENV) up -d osionos-app

live-data-ensure: ## Converge the osionos live-database credential; issues a key when none
## Converge the osionos LIVE-DATABASE credential: issue the tenant API key when ./.env.local has
## none (its cleartext is returned ONCE at issue time and is unrecoverable, so a lost .env.local can
## only be repaired by issuing a new one) and re-stamp the seeded demo rows onto the new owner
## principal in the same step — a new key has a new uuid, and owner-scoped reads would otherwise
## return ZERO rows: authenticated, silent, empty. Idempotent: a converged stack no-ops.
	@bash scripts/ensure-live-data-access.sh

live-data-check: ## Report whether the live-database credential is converged; changes nothing
## Report whether the live-database credential is converged; non-zero if a repair is needed. Changes
## nothing — safe for CI and healthcheck.
	@bash scripts/ensure-live-data-access.sh --check

mounts-reencrypt: ## Re-encrypt live mounts whose DSN no longer opens under VAULT_ENC_KEY
## Repair live mounts whose stored DSN ciphertext no longer opens under the CURRENT VAULT_ENC_KEY
## (every /connect 500s). On a machine with no vault42 keystore, grobase SELF-GENERATES its secrets,
## so regenerating them while the database survives orphans every ciphertext. Re-encrypts via the
## registry itself, preserving mount ids so no reference breaks. Idempotent.
	@bash scripts/reencrypt-mounts.sh

mounts-check: ## Report which live mounts fail to decrypt; changes nothing
## Non-zero if any mount fails to decrypt.
	@bash scripts/reencrypt-mounts.sh --check

models-migrate: ## Apply the models/*.sql migrations that target grobase's public schema
## Apply every models/*.sql migration that targets the grobase postgres public schema (idempotent;
## skips the auth-gateway-shaped files and the superseded surface-constraint steps — see the script
## header). models/ had NO runner: on this machine ELEVEN migrations had never been applied, and the
## missing osionos_pages.cover_position column alone made every page save 502 and stalled the whole
## page-sync outbox — nothing persisted, reloads wiped work.
	@sh scripts/apply-models-migrations.sh

models-check: ## Report unapplied models migrations; non-zero if any
## Changes nothing.
	@sh scripts/apply-models-migrations.sh --check

models-grants-verify: ## Prove on a throwaway DB that only service_role reaches osionos_* tables
## Prove on a throwaway database that every public.osionos_* relation is reachable by service_role
## ONLY — the bridge (service_role) is the only reader and writer. Two scenarios (fresh, and an
## upgraded install still carrying the old blanket grants), both driven by the REAL runner;
## anon/authenticated must get no privilege, no policy and 42501 on six live probes. Changes nothing
## outside its own containers; non-zero on any failure, and a missing image is a FAIL rather than a
## SKIP.
	@sh scripts/verify/models-grants.sh

account-load: ## Run 10K-user seed + latency budgets on throwaway DB (baseline for P0-5/P1-1)
## Spins up a throwaway grobase postgres (--network none), applies grobase init + 012 + shim +
## apply-models-migrations.sh, seeds 10K users + workspaces + pages + connections + feed shares,
## runs ANALYZE, then executes each query from scripts/verify/account-load/queries.sql RUNS times
## (default 30) with EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON). Records p50/p95 execution time
## and whether plan contains Seq Scan on tables listed in budgets.json. Outputs PASS/FAIL per
## query and JSON to target/account-load/<timestamp>.json. Exit 0 = all within budget, 1 = breach,
## 2 = docker missing. Use --baseline to report without failing.
	@sh scripts/verify/account-load.sh

account-load-baseline: ## Run account-load in baseline mode (reports only, exit 0)
	@sh scripts/verify/account-load.sh --baseline

##@ CI (BaaS gate — each job is one make target)
baas-ci-go: ## Go control-plane: vet + unit tests (containerised)
## Usage: make baas-ci-go
## Requires apps/grobase checked out. Same command the BaaS CI workflow runs.
	@test -d apps/grobase/src/control-plane || { echo "apps/grobase not checked out"; exit 1; }
	docker run --rm -v "$(CURDIR)/apps/grobase/src/control-plane:/src" -w /src \
		golang:1.25-bookworm sh -c "go vet ./... && go test ./..."

baas-ci-rust-data-plane: ## Rust data-plane-router: cargo test --workspace
## Usage: make baas-ci-rust-data-plane
	@test -d apps/grobase/src/data-plane-router || { echo "apps/grobase not checked out"; exit 1; }
	docker run --rm -e CARGO_NET_RETRY=10 -e CARGO_HTTP_MULTIPLEXING=false \
		-v "$(CURDIR)/apps/grobase/src/data-plane-router:/src" -w /src \
		rust:1-bookworm cargo test --workspace

baas-ci-rust-realtime: ## Rust realtime plane: cargo test --workspace
## Usage: make baas-ci-rust-realtime
	@test -d apps/grobase/infra/docker/services/realtime/realtime-agnostic || { echo "apps/grobase not checked out"; exit 1; }
	docker run --rm -e CARGO_NET_RETRY=10 -e CARGO_HTTP_MULTIPLEXING=false \
		-v "$(CURDIR)/apps/grobase/infra/docker/services/realtime/realtime-agnostic:/src" -w /src \
		rust:1-bookworm cargo test --workspace

baas-ci-static: ## Package manifest parity + Prometheus config check
## Usage: make baas-ci-static
	@test -d apps/grobase || { echo "apps/grobase not checked out"; exit 1; }
	@cd apps/grobase && \
		diff <(jq -S . infra/config/packages/packages.json) \
		     <(jq -S . src/control-plane/internal/packages/packages.json) \
		&& echo "package manifest is the single source of truth"
	@cd apps/grobase && \
		docker run --rm --entrypoint promtool \
			-v "$$PWD/infra/config/prometheus":/etc/prometheus \
			prom/prometheus:v2.52.0 check config /etc/prometheus/prometheus.yml
	@cd apps/grobase && shellcheck -S error scripts/verify/m*.sh || true
