grobase-up: docker-prefetch-images
## Start the Grobase marketing site dev server (http://127.0.0.1:4324).
	$(MAKE) compose-build BAKE_GROUP=grobase BAKE_TARGETS='grobase-site'
	docker compose --profile grobase up -d --no-build --pull never grobase-site

grobase-logs:
## Follow Grobase marketing site logs.
	docker compose --profile grobase logs -f grobase-site

grobase-down:
## Stop the Grobase marketing site containers.
	docker compose --profile grobase stop grobase-site

grobase-audit:
## Run the full Grobase quality gate: prod build + preview + Lighthouse (>=90 x4
## on /, /pricing, /security) + pa11y + CSP check + html-validate. Fails on any gate.
	docker compose --profile grobase build grobase-site-audit
	docker compose --profile grobase run --rm grobase-site-audit

grobase-e2e:
## Run the Playwright end-to-end suite (story spine, scroll morph, one-shot Big
## Bang, latch, reduced-motion + no-JS dignity, CSP/console cleanliness, keyboard
## explorer) against a prod preview, using the audit image's system Chromium.
	docker compose --profile grobase build grobase-site-audit
	docker compose --profile grobase run --rm grobase-site-audit npm run test:e2e

# --- Grobase backend integration (standalone apps/grobase stack = docker project mini-baas) ---
.PHONY: backend-up frontends-up

# Frontends the root pipeline owns. The backend (postgres/gotrue/kong/postgrest/...)
# is the running apps/grobase stack and must NOT be re-upped from here.
ROOT_FRONTENDS := osionos-bridge osionos-app auth-gateway opposite-osiris-web local-https-proxy livekit

# Engine set `make all` brings up on a fresh machine. Default `devlean` = the daily-dev
# shape: every CORE engine (postgres mongo redis minio, all public images) + full
# app/control/data plane + realtime, but WITHOUT the heavy à-la-carte extra-engines plane
# (mysql/mariadb/cockroach/mssql, ~750 MiB — cockroach alone ~590 MiB) and WITHOUT the
# monitoring/lakehouse extras that come up unhealthy in a constrained env. osionos uses
# none of the extra engines, so nothing is lost — and the constrained host stops thrashing.
# The extra DB engines are one flag away: `make all GROBASE_EDITION=migrate` (all snapshot
# engines, the old default) or `=full` (everything-on). dynamodb stays out (private images).
GROBASE_EDITION ?= devlean

backend-up:
## Ensure the grobase backend is up — START it if it's down (not just guard), so a bare `make all` reconstitutes a clean machine. Brings up GROBASE_EDITION (default migrate). With a vault key, secrets are pulled earlier by `secrets-ensure`; with NO vault key, grobase self-generates its secrets (no-vault local mode) and `env-local-ensure` derives the root ./.env.local afterward.
	@if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q '^mini-baas_mini-baas$$' \
		&& docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mini-baas-kong$$'; then \
		exit 0; \
	fi; \
	if [ ! -f apps/grobase/.env ] && [ ! -f "$(CTL_CFG_DIR)/keystore.v42" ]; then \
		echo '[backend] no vault key — LOCAL mode: grobase will self-generate its secrets (make -C apps/grobase env).' >&2; \
	fi; \
	echo "[backend] starting grobase backend (EDITION=$(GROBASE_EDITION))…" >&2; \
	$(MAKE) -C apps/grobase up EDITION=$(GROBASE_EDITION)

restore-if-empty:
## FAIL-SAFE auto-restore (wired into `make all`): loads the all-engine snapshot ONLY when EVERY running primary engine (postgres osionos, mysql ops, mongo activity) is CONFIRMED empty. Any engine with data, or any uncertainty (unreachable / query error), → SKIP (never wipes). Logic in scripts/restore-if-empty.sh.
	@sh scripts/restore-if-empty.sh

apply-models:
## Apply pending root-app models/*.sql migrations to the live DB (checksum-tracked; ADOPTS an existing schema on first run, then applies only new/changed files — never blindly replays order-sensitive migrations). Wired into `make all`. Logic in scripts/apply-models.sh.
	@sh scripts/apply-models.sh apply

apply-models-check:
## Verify GATE (read-only): exit non-zero if any models/*.sql migration is pending (committed but unapplied) — the guard that catches the class of bug where a migration silently never ran. Wire into CI.
	@sh scripts/apply-models.sh check

apply-models-baseline:
## Adopt the migration ledger on an already-migrated DB: record every current models/*.sql as applied WITHOUT running it.
	@sh scripts/apply-models.sh baseline

frontends-up: certs docker-prefetch-images compose-build
## Build and start ONLY the root frontends against the running grobase backend. Also
## resurrects the IDE plane containers (runner / sandbox socket-proxy) — but ONLY when
## ./.env.local records them as activated (see IDE-BACKLOG.md); fresh machines skip both.
	docker compose --env-file ./.env.local up -d --build --wait $(ROOT_FRONTENDS)
	@grep -qs '^OSIONOS_RUNNER_URL=.' ./.env.local && \
		COMPOSE_PROFILES=runner docker compose --env-file ./.env.local up -d osionos-runner || true
	@grep -qs '^OSIONOS_IDE_SANDBOX=1' ./.env.local && \
		COMPOSE_PROFILES=ide docker compose --env-file ./.env.local up -d osionos-ide-socket-proxy || true
	$(MAKE) compose-wait
