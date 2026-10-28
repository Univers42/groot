# --- Grobase backend integration (standalone apps/grobase stack = docker project mini-baas) ---

# Frontends the root pipeline owns. The backend (postgres/gotrue/kong/postgrest/...)
# is the running apps/grobase stack and must NOT be re-upped from here.
#
# $(DRAWNOSAURUS_SERVICES) is the Whiteboard plane, default-on since T12-P1b. Referenced
# rather than repeated — drawnosaurus.mk is included first (Makefile:45 before :49), so the
# list has one definition. Its wasm artifact is a build INPUT for drawnosaurus-web, which is
# why frontends-up takes drawnosaurus-wasm as a prerequisite below and not as a step inside
# the recipe: `up -d --build` would otherwise build the web image against a missing pkg/.
# hydrawn-web (the whiteboard that replaces it, hydrawn.mk) is listed literally: hydrawn.mk
# sorts after this file, so HYDRAWN_SERVICES is not yet defined here. Same wasm rule.
ROOT_FRONTENDS := osionos-bridge osionos-app auth-gateway opposite-osiris-web local-https-proxy livekit $(DRAWNOSAURUS_SERVICES) hydrawn-web

# The ROOT_FRONTENDS images this repo builds that also have a published Docker Hub tag.
# `frontends-up PULL_PREBUILT=1` pulls these tags instead of building; an *_IMAGE already
# set in the environment still wins.
PREBUILT_SERVICES := osionos-bridge osionos-app auth-gateway opposite-osiris-web
PREBUILT_IMAGE_EXPORTS := \
	export OSIONOS_BRIDGE_IMAGE="$${OSIONOS_BRIDGE_IMAGE:-dlesieur/osionos-bridge:latest}" \
	OSIONOS_APP_IMAGE="$${OSIONOS_APP_IMAGE:-dlesieur/osionos-app:latest}" \
	OSIONOS_RUNNER_IMAGE="$${OSIONOS_RUNNER_IMAGE:-dlesieur/osionos-runner:latest}" \
	AUTH_GATEWAY_IMAGE="$${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}" \
	OPPOSITE_OSIRIS_WEB_IMAGE="$${OPPOSITE_OSIRIS_WEB_IMAGE:-dlesieur/opposite-osiris-web:latest}"

# Engine set `make all` brings up on a fresh machine. Default `devlean` = the daily-dev
# shape: every CORE engine (postgres mysql mongo redis minio, all public images — mysql lives
# in the data plane) + full app/control/data plane + realtime, but WITHOUT the heavy à-la-carte
# extra-engines plane (mariadb/cockroach/mssql, ~750 MiB — cockroach alone ~590 MiB) and WITHOUT the
# monitoring/lakehouse extras that come up unhealthy in a constrained env. osionos uses
# none of the extra engines, so nothing is lost — and the constrained host stops thrashing.
# The extra DB engines are one flag away: `make all GROBASE_EDITION=migrate` (all snapshot
# engines, the old default) or `=full` (everything-on). dynamodb stays out (private images).
GROBASE_EDITION ?= devlean

##@ Backend (grobase)
backend-up: ## Ensure the grobase backend is up, starting it when it is down
## Usage: make backend-up [GROBASE_EDITION=devlean|migrate|full]
## Ensure the grobase backend is up — START it if it's down (not just guard), so a bare `make all`
## reconstitutes a clean machine. Brings up GROBASE_EDITION (default devlean; CI passes migrate).
## With a vault key, secrets are pulled earlier by `secrets-ensure`; with NO vault key, grobase
## self-generates its secrets (no-vault local mode) and `env-local-ensure` derives the root
## ./.env.local afterward.
	@if docker ps -q --filter label=com.docker.compose.service=grobase-link 2>/dev/null | grep -q .; then \
		echo '[backend] the grobase-link relay is running: grobase is reached elsewhere (make link-status). Refusing to start a second one under the same names; make link-down first.' >&2; \
		exit 1; \
	fi; \
	if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q '^mini-baas_mini-baas$$' \
		&& docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mini-baas-kong$$'; then \
		exit 0; \
	fi; \
	if [ ! -f apps/grobase/.env ] && [ ! -f "$(CTL_CFG_DIR)/keystore.v42" ]; then \
		echo '[backend] no vault key — LOCAL mode: grobase will self-generate its secrets (make -C apps/grobase env).' >&2; \
	fi; \
	echo "[backend] starting grobase backend (EDITION=$(GROBASE_EDITION))…" >&2; \
	$(MAKE) -C apps/grobase up EDITION=$(GROBASE_EDITION)

restore-if-empty: ## Restore data only when every running primary engine is confirmed empty
## Usage: make restore-if-empty [GROBASE_EDITION=<edition>]
## FAIL-SAFE auto-restore (wired into `make all`): loads data ONLY when every running primary engine
## (postgres osionos, mysql ops, mongo activity) is CONFIRMED empty and postgres is running. Source:
## the vault seeds in ./secrets when present (checksum-verified, all engines, via `make
## vault-restore`), else the committed git snapshot. A failed or unfinished vault restore stops
## `make all` and names the resume command (`make vault-restore`) — it is never mistaken for data on
## a later run. Logic in scripts/restore-if-empty.sh.
	@GROBASE_EDITION="$(GROBASE_EDITION)" sh scripts/restore-if-empty.sh

##@ Secrets (vault42)
vault42-seed: ## Capture every running engine's data into ./secrets; never deletes
## Capture every RUNNING engine's data into ./secrets — the exact file set `make vault-restore`
## replays, and what `make vault42-push-all` then sends to the vault. Records coverage in
## secrets/MANIFEST.json; never deletes. Bring the engines-extra profile up first if you want mssql
## + dynamodb covered.
	@mkdir -p "$(CURDIR)/secrets"
	$(MAKE) -C apps/grobase vault-seed SEED_DIR="$(CURDIR)/secrets"

vault-restore: ## DESTRUCTIVE: replay the ./secrets vault seeds over the running engines
## Usage: make vault-restore [FETCH=1] [EDITION=<edition>]
## Rebuild every engine's DATA from the 42ctl vault seeds in ./secrets (newer + more engines than
## the git snapshot `restore-if-empty` uses). DESTRUCTIVE — replays dumps over the running engines.
## FETCH=1 pulls the seeds from the vault first.
	@[ -d "$(CURDIR)/secrets" ] || { \
		printf 'no ./secrets here — the vault seeds are not on disk.\n' >&2; \
		printf 'Pull them first: make vault42-pull-all APPLY=1   (or pass FETCH=1)\n' >&2; \
		[ -n "$(FETCH)" ] || exit 1; \
	}
	$(MAKE) -C apps/grobase vault-restore SEED_DIR="$(CURDIR)/secrets" \
		$(if $(FETCH),FETCH=$(FETCH),) EDITION="$(or $(EDITION),$(GROBASE_EDITION))"

# The import CLI refuses a missing ID or DEST itself (exit 2), so these only forward; recipes are
# silent so stdout stays the CLI's (a path, or status JSON for jq). The b2b
# ssh alias carries port forwards that collide with a running link; a transfer needs none.
GROBASE_IMPORT = RSYNC_RSH="$${RSYNC_RSH:-ssh -o ClearAllForwardings=yes -o LogLevel=ERROR}" \
	bash apps/grobase/scripts/ops/grobase-import.sh

##@ Backend (grobase)
import-pack: ## Stage ./secrets as a checksummed import dir; touches no database
## Usage: make import-pack [ID=<import-id>] [SEED_DIR=<dir>] [FORCE=1]
## Stage ./secrets (or SEED_DIR=) as a checksummed import dir holding only the captured dumps, under
## ~/.local/state/grobase/import. ID= names it (default seeds-<utc>), FORCE=1 replaces it. Touches
## no database.
	@$(GROBASE_IMPORT) pack "$(or $(SEED_DIR),$(CURDIR)/secrets)" $(if $(ID),--id '$(ID)',) $(if $(FORCE),--force,)

import-push: ## Re-verify an import dir, then rsync it to the data center
## Usage: make import-push ID=<import-id> [DEST=host:/path] [DRY=1]
## Re-verify import ID= here, then rsync it to DEST=host:/path (else the GROBASE_IMPORT_DEST env
## var), e.g. DEST=b2b:/var/lib/grobase-import. Never sends state/. DRY=1 lists the files and sends
## nothing.
	@$(GROBASE_IMPORT) push '$(ID)' $(if $(DEST),--dest '$(DEST)',) $(if $(DRY),--dry-run,)

import-status: ## Print an import's manifest and per-packet state as one JSON object
## Usage: make import-status ID=<import-id>
	@$(GROBASE_IMPORT) status '$(ID)'

import-rebind: ## Re-seal an import's mount rows under the data center's key
## Usage: make import-rebind ID=<import-id> NEW=<new-id> TARGET=<ssh-host> [FORCE=1]
## Derive import NEW= from import ID= for the data center TARGET= (ssh host, e.g. b2b): every mount
## row this host's VAULT_ENC_KEY opens is re-sealed under the target's key, with the target's engine
## passwords. Keys are read over ssh, never printed. Touches no database.
	@bash apps/grobase/scripts/ops/grobase-import-rebind.sh '$(ID)' '$(NEW)' $(if $(TARGET),--target-ssh '$(TARGET)',) $(if $(FORCE),--force,)

import-apply: ## Replay a pushed import into the data center's engines; needs CONFIRM=1
## Usage: make import-apply ID=<import-id> [DEST=host:/path] [CONFIRM=1] [FORCE=1]
## Replay pushed import ID= into the data center's engines (DEST=host:/path, else
## GROBASE_IMPORT_DEST). Prints the plan only, unless CONFIRM=1: stop its stack, snapshot the engine
## volumes, restore, check counts, migrate, restart what ran. FORCE=1 re-applies.
	@bash scripts/grobase-import-remote.sh apply '$(ID)' $(if $(DEST),--dest '$(DEST)',) $(if $(CONFIRM),--confirm,) $(if $(FORCE),--force,)

import-rollback: ## Roll the data center back to its pre-apply snapshot; needs CONFIRM=1
## Usage: make import-rollback ID=<import-id> [DEST=host:/path] [CONFIRM=1]
## Put the data center's engine volumes back from import ID='s apply snapshot, then restart what ran
## before apply. Plan only, unless CONFIRM=1.
	@bash scripts/grobase-import-remote.sh rollback '$(ID)' $(if $(DEST),--dest '$(DEST)',) $(if $(CONFIRM),--confirm,)

apply-models: ## Apply pending models/*.sql migrations to the live DB; manual only
## Apply pending root-app models/*.sql migrations to the live DB (checksum-tracked; applies only
## new/changed files). MANUAL ONLY — deliberately NOT in `make all`: on an EMPTY database it runs
## all files in alphabetical order, and the notification-type migrations (comments / feed-engagement
## / tasks) are order-sensitive, so the result silently drops `page_comment`; user.sql / gdpr /
## auth-security also fail there against the uuid `users` table. CAUTION: on a populated database
## with an empty ledger it ADOPTS — records every file as applied WITHOUT running it — which is how
## 23 tables came to be missing while the ledger said all 34 had run. Check the objects exist before
## trusting it. Logic in scripts/apply-models.sh.
	@sh scripts/apply-models.sh apply

apply-models-check: ## Exit non-zero if any models/*.sql migration is pending (read-only)
## Verify GATE (read-only): exit non-zero if any models/*.sql migration is pending (committed but
## unapplied) — the guard that catches the class of bug where a migration silently never ran. Wire
## into CI.
	@sh scripts/apply-models.sh check

apply-models-baseline: ## Mark every current models/*.sql as applied WITHOUT running it
## Adopt the migration ledger on an already-migrated DB: record every current models/*.sql as
## applied WITHOUT running it.
	@sh scripts/apply-models.sh baseline

frontends-up: submodules-pinned certs drawnosaurus-wasm hydrawn-wasm ## Build and start only the root frontends against the running backend
## Usage: make frontends-up [PULL_PREBUILT=1]
## Build and start ONLY the root frontends against the running grobase backend. Also resurrects the
## IDE plane containers (runner / sandbox socket-proxy) — but ONLY when ./.env.local records them as
## activated (see IDE-BACKLOG.md); fresh machines skip both. Builds only what it starts: the bake
## group (compose-build) makes :local images that nothing here runs, and a fresh machine has a 20-30
## GB /var to share. Our images build from source as track-binocle/*:local. PULL_PREBUILT=1 instead
## pulls the published dlesieur/*:latest tags for them and starts everything with --no-build
## (services with no published image are still built first). Nothing here ever pushes.
	@$(MAKE) --no-print-directory docker-prefetch-images DOCKER_PREFETCH_SCOPE=frontends
	@set -eu; \
	compose='docker compose --env-file ./.env.local'; \
	build=--build; \
	if [ '$(PULL_PREBUILT)' = 1 ]; then \
		$(PREBUILT_IMAGE_EXPORTS); \
		$$compose pull $(PREBUILT_SERVICES); \
		$$compose build $(filter-out $(PREBUILT_SERVICES),$(ROOT_FRONTENDS)); \
		build=--no-build; \
	fi; \
	$(WITH_GRAPH_RENDER_SHA) \
	TRACK_BINOCLE_BIND_ADDR="$$(sh infrastructure/scripts/detect-bind-addr.sh)" $$compose up -d $$build --wait $(ROOT_FRONTENDS); \
	if grep -qs '^OSIONOS_RUNNER_URL=.' ./.env.local; then \
		COMPOSE_PROFILES=runner $$compose up -d osionos-runner || true; \
	fi; \
	if grep -qs '^OSIONOS_IDE_SANDBOX=1' ./.env.local; then \
		COMPOSE_PROFILES=ide $$compose up -d osionos-ide-socket-proxy || true; \
	fi
	$(MAKE) compose-wait

compose-wait: ## Wait for services to become healthy and init jobs to exit cleanly
	@set -eu; \
	deadline=$$((SECONDS + $(COMPOSE_WAIT_TIMEOUT))); \
	while true; do \
		pending=''; failed=''; \
		for service in $(COMPOSE_HEALTHY_SERVICES); do \
			cid="$$(docker compose ps -q "$$service" 2>/dev/null || true)"; \
			if [[ -z "$$cid" ]]; then pending="$$pending $$service(no-container)"; continue; fi; \
			state="$$(docker inspect -f '{{.State.Status}}' "$$cid")"; \
			health="$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$$cid")"; \
			if [[ "$$state" == 'exited' || "$$state" == 'dead' ]]; then failed="$$failed $$service($$state)"; continue; fi; \
			if [[ "$$health" != 'healthy' ]]; then pending="$$pending $$service($$health)"; fi; \
		done; \
		for service in $(COMPOSE_RUNNING_SERVICES); do \
			cid="$$(docker compose ps -q "$$service" 2>/dev/null || true)"; \
			if [[ -z "$$cid" ]]; then pending="$$pending $$service(no-container)"; continue; fi; \
			state="$$(docker inspect -f '{{.State.Status}}' "$$cid")"; \
			if [[ "$$state" != 'running' ]]; then pending="$$pending $$service($$state)"; fi; \
		done; \
		for service in $(COMPOSE_COMPLETED_SERVICES); do \
			cid="$$(docker compose ps -a -q "$$service" 2>/dev/null || true)"; \
			if [[ -z "$$cid" ]]; then pending="$$pending $$service(no-container)"; continue; fi; \
			state="$$(docker inspect -f '{{.State.Status}}' "$$cid")"; \
			exit_code="$$(docker inspect -f '{{.State.ExitCode}}' "$$cid")"; \
			if [[ "$$state" == 'exited' && "$$exit_code" == '0' ]]; then continue; fi; \
			if [[ "$$state" == 'exited' ]]; then failed="$$failed $$service(exit=$$exit_code)"; else pending="$$pending $$service($$state)"; fi; \
		done; \
		if [[ -n "$$failed" ]]; then echo "[compose] failed:$$failed"; docker compose ps; exit 1; fi; \
		if [[ -z "$$pending" ]]; then echo '[compose] services ready'; exit 0; fi; \
		if [[ "$$SECONDS" -ge "$$deadline" ]]; then echo "[compose] timed out waiting for:$$pending"; docker compose ps; exit 1; fi; \
		echo "[compose] waiting for:$$pending"; \
		sleep '$(COMPOSE_WAIT_INTERVAL)'; \
	done
