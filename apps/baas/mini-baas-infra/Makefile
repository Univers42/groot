# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile  (layer/edition orchestrator)            :+:      :+:    :+:     #
#                                                     +:+ +:+         +:+       #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+          #
#                                                 +#+#+#+#+#+   +#+             #
#    mini-baas — one control surface for a swappable-layer BaaS                #
#    The previous 641-line file is preserved as Makefile.legacy.               #
#    Anything not defined here is reachable via:  make legacy-<target>         #
#                                                                              #
# **************************************************************************** #

SHELL          := /bin/bash
.SHELLFLAGS    := -ec
.DEFAULT_GOAL  := help

# --------------------------------------------------------------------------- #
#  Variables                                                                   #
# --------------------------------------------------------------------------- #
PROJECT        := mini-baas
COMPOSE_FILE   ?= docker-compose.yml
IMAGE_TAG      ?= latest
REGISTRY       ?= localhost:5000
SERVICE        ?=
STEPS          ?= 1
HOOKS_DIR      := vendor/scripts/hooks
DC             := docker compose -f $(COMPOSE_FILE)

# Colors
_B := \033[0;34m
_G := \033[0;32m
_Y := \033[1;33m
_R := \033[0;31m
_C := \033[0;36m
_W := \033[1m
_D := \033[2m
_0 := \033[0m

# ========================================================================== #
#  THE MANIFEST — single source of truth (see wiki/02-layer-edition-model.md) #
# ========================================================================== #
# A PLANE is a capability slice mapped to compose profile(s).
# An EDITION is a named, validated set of planes ("a known-good shape").
# Every up-/down-/logs- target below is GENERATED from these two maps, so
# adding a plane or an edition is a one-line change — never a new recipe.

PLANES := data control go rust adapter background analytics storage realtime \
          functions observability ops studio playground

# plane -> compose profile(s)
PROFILES_data          := data-plane
PROFILES_control       := control-plane
PROFILES_go            := go-control-plane
PROFILES_rust          := rust-data-plane
PROFILES_adapter       := adapter-plane
PROFILES_background    := background
PROFILES_analytics     := analytics
PROFILES_storage       := storage
PROFILES_realtime      := realtime
PROFILES_functions     := functions
PROFILES_observability := observability
PROFILES_ops           := ops backups
PROFILES_studio        := studio
PROFILES_playground    := playground

EDITIONS := lean query realtime analytics prod full

# edition -> plane list  (core, profile-less, is always included)
EDITION_lean      :=
EDITION_query     := data go rust adapter background
EDITION_realtime  := data go rust adapter background realtime storage
EDITION_analytics := data storage analytics
EDITION_prod      := data go rust adapter background storage realtime observability ops
# `playground` is a demo UI whose static assets are NOT checked into this repo, so its
# bind-mount (./playground) has nothing to serve. Excluded from `full` so `make up
# EDITION=full` comes up clean; restore the playground/ assets + drop the filter to re-enable.
EDITION_full      := $(filter-out playground,$(PLANES))

# Which edition `make up` / `make down` operate on by default.
EDITION ?= query

# Functions: plane-list -> sorted profiles -> `--profile x --profile y`
profiles_of = $(sort $(foreach p,$(1),$(PROFILES_$(p))))
flags_of    = $(addprefix --profile ,$(call profiles_of,$(1)))

# Active profiles for the generic edition-driven verbs. `PROFILES=` overrides
# the edition for ad-hoc shapes:  make up PROFILES="data-plane storage"
ifndef PROFILES
ACTIVE_PROFILES := $(call profiles_of,$(EDITION_$(EDITION)))
else
ACTIVE_PROFILES := $(PROFILES)
endif
PROFILE_FLAGS := $(addprefix --profile ,$(ACTIVE_PROFILES))
DCE           := $(DC) $(PROFILE_FLAGS)

# --------------------------------------------------------------------------- #
#  Internal prerequisites (no ## = hidden from help)                           #
# --------------------------------------------------------------------------- #
_require-docker:
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Docker is not installed."; exit 1; }

_require-compose: _require-docker
	@docker compose version >/dev/null 2>&1 || { echo >&2 "Docker Compose v2 plugin is required."; exit 1; }

_rm-stale:
	@ids=$$(docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' | awk '/ mini-baas-/ && ($$3=="Created"||$$3=="Exited") {print $$1}'); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing stale containers…$(_0)"; docker rm -f $$ids >/dev/null; }

# ========================================================================== #
##@ 42 Classics
# ========================================================================== #
all: ## Build images & start the default EDITION
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory up

all-full: ## Build & start the FULL edition
	@$(MAKE) --no-print-directory EDITION=full all

clean: down ## Stop the current edition (alias for down)

fclean: _require-compose ## Destructive: stop everything, prune containers/volumes/images/cache
	@echo -e "$(_Y)$(_W)Running destructive Docker cleanup…$(_0)"
	@$(DC) $(call flags_of,$(PLANES)) down --volumes --remove-orphans 2>/dev/null || true
	@ids=$$(docker ps -aq); [ -z "$$ids" ] || docker rm -f $$ids >/dev/null 2>&1 || true
	@docker system prune -af --volumes >/dev/null 2>&1 || true
	@docker builder prune -af >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ Full Docker clean complete$(_0)"

re: ## Full reset: fclean then rebuild & start (honours EDITION)
	@$(MAKE) --no-print-directory fclean
	@$(MAKE) --no-print-directory all

# ========================================================================== #
##@ Stack (edition-driven — set EDITION=lean|query|realtime|analytics|prod|full)
# ========================================================================== #
up: _require-compose _rm-stale ## Start the selected EDITION (detached)
	@echo -e "$(_B)Starting edition '$(_W)$(EDITION)$(_0)$(_B)' → profiles: $(_C)$(ACTIVE_PROFILES)$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d $(SERVICE)
	@echo -e "$(_G)✓ Up$(_0)"

down: _require-compose ## Stop & remove the selected EDITION
	@$(DCE) down
	@echo -e "$(_G)✓ Down$(_0)"

restart: _require-compose ## Restart (SERVICE=<name> to target one)
	@$(DCE) restart $(SERVICE)
	@echo -e "$(_G)✓ Restarted$(_0)"

ps: _require-compose ## Show service status for the selected EDITION
	@$(DCE) ps

logs: _require-compose ## Follow logs (SERVICE=<name> to filter)
	@$(DCE) logs -f --tail=100 $(SERVICE)

pull: _require-compose ## Pull images for the selected EDITION
	@$(DCE) pull
	@echo -e "$(_G)✓ Pulled$(_0)"

build: _require-compose ## Build images for the selected EDITION (BuildKit, parallel)
	@DOCKER_BUILDKIT=1 $(DCE) build --build-arg BUILDKIT_INLINE_CACHE=1
	@echo -e "$(_G)✓ Build complete$(_0)"

build-svc-%: _require-compose ## Build ONE service image (all profiles defined, builds only $*; e.g. make build-svc-query-router)
	@DOCKER_BUILDKIT=1 $(DC) $(call flags_of,$(PLANES)) build $*
	@echo -e "$(_G)✓ built $*$(_0)"

health: ## Quick gateway health probe
	@echo -e "$(_B)Checking endpoints…$(_0)"
	@curl -fsS http://localhost:8000/auth/v1/health >/dev/null && echo "  ✓ /auth/v1/health" || echo "  ✗ /auth/v1/health"
	@curl -fsS http://localhost:8000/rest/v1/ >/dev/null && echo "  ✓ /rest/v1/" || echo "  ✗ /rest/v1/"

bench-startup: _require-compose _rm-stale ## Time the stack until health checks pass (target ≤90s)
	@t0=$$(date +%s); eval "$$(bash scripts/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d; \
	for svc in mini-baas-postgres mini-baas-gotrue mini-baas-postgrest mini-baas-kong; do \
		printf "  Waiting: %-26s" "$$svc"; \
		timeout 120 sh -c "while [ \"$$(docker inspect --format='{{.State.Health.Status}}' $$svc 2>/dev/null)\" != 'healthy' ]; do sleep 1; done" 2>/dev/null \
			&& echo -e "$(_G)✓$(_0)" || echo -e "$(_R)✗ (timeout)$(_0)"; \
	done; \
	t1=$$(date +%s); el=$$((t1-t0)); \
	[ "$$el" -le 90 ] && echo -e "$(_G)$(_W)✓ healthy in $${el}s$(_0)" || echo -e "$(_R)$(_W)✗ $${el}s (>90s)$(_0)"

# ========================================================================== #
##@ Planes (change layers live — up-<plane> / down-<plane> / logs-<plane>)
# ========================================================================== #
# These targets are GENERATED from $(PLANES). One eval loop → every verb for
# every plane, with zero repeated recipes. Run `make planes` to list them.
define PLANE_RULES
up-$(1): _require-compose ## (generated) start the '$(1)' plane on a running core
	@echo -e "$(_B)+ plane $(_W)$(1)$(_0) → $(_C)$(PROFILES_$(1))$(_0)"
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) up -d $$(SERVICE)

down-$(1): _require-compose ## (generated) stop the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) stop $$(SERVICE)

restart-$(1): _require-compose ## (generated) restart the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) restart $$(SERVICE)

logs-$(1): _require-compose ## (generated) follow the '$(1)' plane logs
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) logs -f --tail=100 $$(SERVICE)
endef
$(foreach p,$(PLANES),$(eval $(call PLANE_RULES,$(p))))

observe: up-observability ## Alias: start the observability plane
	@echo -e "  Grafana: http://localhost:3030   Prometheus: http://localhost:9090"

planes: ## List planes and the profiles they activate
	@echo -e "$(_W)$(_C)Planes$(_0)  (use: make up-<plane> / down-<plane> / logs-<plane>)"
	@$(foreach p,$(PLANES),printf "  $(_G)%-14s$(_0) $(_D)%s$(_0)\n" "$(p)" "$(PROFILES_$(p))";)

editions: ## List editions and the planes they include
	@echo -e "$(_W)$(_C)Editions$(_0)  (use: make up EDITION=<name>)"
	@$(foreach e,$(EDITIONS),printf "  $(_G)%-10s$(_0) $(_D)%s$(_0)\n" "$(e)" "$(if $(EDITION_$(e)),$(EDITION_$(e)),core only)";)

doctor: ## Environment sanity check
	@echo -e "$(_B)Doctor$(_0)"
	@command -v docker >/dev/null 2>&1 && echo "  ✓ docker" || echo "  ✗ docker"
	@docker compose version >/dev/null 2>&1 && echo "  ✓ compose v2" || echo "  ✗ compose v2"
	@[ -f .env ] && echo "  ✓ .env present" || echo "  • .env missing (run: make env)"
	@echo "  • EDITION=$(EDITION) → profiles: $(ACTIVE_PROFILES)"

# ========================================================================== #
##@ Tests & verification
# ========================================================================== #
tests: ## Run all phase smoke tests (phase1→N)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	export PUBLIC_APIKEY=$${PUBLIC_APIKEY:-$$APIKEY}; \
	export SERVICE_ROLE_KEY=$${SERVICE_ROLE_KEY:-$$(grep '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	rc=0; for s in $$(ls -1 ./scripts/phase*-*.sh ./scripts/phase*-*.py 2>/dev/null | sort -t/ -k3 -V); do \
		case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac || rc=1; sleep 1; \
	done; exit $$rc

test-phase%: ## Run one phase (e.g. make test-phase3)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	s=$$(ls scripts/phase$*-*.sh scripts/phase$*-*.py 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No test for phase $*$(_0)"; exit 1; }; \
	case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac

test-postgres: ## Run the PostgreSQL MVP happy-path flow
	@FORCE_COLORS=1 bash ./scripts/postgres-mvp-flow.sh

verify-%: ## Run a milestone gate (e.g. make verify-m18)
	@s=$$(ls scripts/verify/$*-*.sh 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No verify gate '$*'$(_0)"; exit 1; }; \
	bash "$$s"

verify-all: ## Run every milestone gate (m1…m19)
	@rc=0; for s in $$(ls scripts/verify/m*-*.sh | sort -V); do \
		echo -e "$(_B)→ $$s$(_0)"; bash "$$s" || rc=1; done; exit $$rc

parity: ## Layer-swap parity gate (NEW=<url> [OLD=<url>] [ROUTES=<set>] [RECORD=1]) — emits a verdict
	@OLD="$(OLD)" NEW="$(NEW)" ROUTES="$(ROUTES)" bash scripts/verify/parity.sh $(if $(RECORD),--record,)

parity-suite: ## Legacy full-suite TS↔Rust shadow probe (restarts query-router; historical)
	@bash scripts/verify/parity-probe.sh

cutover-%: ## Gated promotion of a plane/service (runs parity, then restarts it) — override NEW=/ROUTES= per plane
	@echo -e "$(_Y)Cutover '$*' — requires a green parity verdict first.$(_0)"
	@$(MAKE) --no-print-directory parity NEW="$(or $(NEW),http://127.0.0.1:4011)" ROUTES="$(or $(ROUTES),data-plane-contract)"
	@$(DCE) up -d --no-deps $* && echo -e "$(_G)✓ '$*' restarted; set its *_PRODUCT_MODE=enabled in .env to make it live$(_0)"

deploy-gen: ## (G11) Compile the edition manifest → Helm values + Kustomize overlays (DEPLOY_REGISTRY=/DEPLOY_TAG= override images)
	@command -v python3 >/dev/null 2>&1 || { echo -e "$(_R)python3 required$(_0)"; exit 1; }
	@python3 scripts/gen-deploy.py

deploy-template: ## (G11) Render an edition's K8s manifests via Helm (EDITION=lean|query|realtime|analytics|prod|full)
	@command -v helm >/dev/null 2>&1 || { echo -e "$(_R)helm required$(_0)"; exit 1; }
	@helm template mini-baas deploy/helm/mini-baas -f deploy/helm/mini-baas/values-$(EDITION).yaml

waf-test: ## Confirm the WAF blocks SQLi/XSS at the edge
	@for q in "?id=1%20OR%201=1" "/<script>alert(1)</script>"; do \
		code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/rest/v1/$$q"); \
		[ "$$code" = "403" ] && echo "  ✓ blocked ($$q)" || echo "  ✗ expected 403, got $$code ($$q)"; \
	done

# ========================================================================== #
##@ Migrations & data
# ========================================================================== #
migrate: ## Apply pending PostgreSQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; sed '/^#/d' "$$f" | $(DC) exec -T postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f -; \
	done; echo -e "$(_G)✓ PostgreSQL migrations applied$(_0)"

migrate-mongo: ## Apply MongoDB migrations
	@for f in $$(ls -1 scripts/migrations/mongodb/*.js 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mongo mongosh mini_baas < "$$f"; done
	@echo -e "$(_G)✓ MongoDB migrations applied$(_0)"

migrate-mysql: ## Apply MySQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/mysql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mysql sh -ec 'mysql -u"$${MYSQL_USER:-mini_baas}" -p"$${MYSQL_PASSWORD:-mini_baas_pw}" "$${MYSQL_DATABASE:-mini_baas}"' < "$$f"; done
	@echo -e "$(_G)✓ MySQL migrations applied$(_0)"

migrate-all: migrate migrate-mongo migrate-mysql ## Apply PG + Mongo + MySQL migrations

migrate-status: ## Show applied migration versions
	@$(DC) exec -T postgres psql -U postgres -d postgres -c "SELECT version, name, applied_at FROM schema_migrations ORDER BY version;" 2>/dev/null || echo "  No migrations table yet — run make migrate."

seed-mongo: _require-compose ## Seed MongoDB demo data
	@bash scripts/seed-mongo.sh

seed-live-demo: _require-compose ## Seed the live-database demo across pg+mysql+mongo (owned by the osionos app key; RESEED=1 wipes first)
	@bash scripts/seed-live-demo.sh

# ========================================================================== #
##@ Secrets & Vault
# ========================================================================== #
secrets: ## Generate all secrets → .env
	@bash scripts/secrets/generate-secrets.sh
secrets-validate: ## Validate required secrets exist
	@bash scripts/secrets/validate-secrets.sh
secrets-rotate: ## Rotate JWT secret (GROUP=jwt|tenant-dsn|all)
	@bash scripts/secrets/rotate-jwt.sh
check-secrets: ## Scan source for hardcoded secrets
	@bash scripts/check-secrets.sh
env: ## Generate .env from template
	@bash scripts/generate-env.sh
vault-init: _require-compose ## Run Vault init/unseal/seed
	@$(DC) --profile control-plane run --rm vault-init
vault-status: _require-compose ## Check Vault seal status
	@docker exec mini-baas-vault vault status -address=http://127.0.0.1:8200 2>/dev/null || echo -e "$(_R)Vault not running$(_0)"
vault-rotate: _require-compose ## Rotate Vault secrets (GROUP=jwt|postgres|mongo|minio|kong|all)
	@docker exec mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}

# ========================================================================== #
##@ Language tiers (TypeScript / Rust / Go)
# ========================================================================== #
# Node also runs INSIDE Docker (no node/npm on the host); node_modules lives
# in a named volume so the host tree stays clean and installs stay warm.
NODE_IMAGE := public.ecr.aws/docker/library/node:20-alpine
NODE_RUN    = docker run --rm -v "$(PWD)/src":/app -w /app \
	-v mini-baas-src-node-modules:/app/node_modules \
	-v mini-baas-npm-cache:/root/.npm \
	$(NODE_IMAGE)

nestjs-ci: ## TS: install + typecheck + lint + test (in Docker)
	@$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund \
		&& npx tsc --noEmit && npx eslint "apps/**/*.ts" "libs/**/*.ts" && npx jest --passWithNoTests'
nestjs-build-%: ## TS: build one app in Docker (e.g. make nestjs-build-query-router)
	@$(NODE_RUN) sh -c '[ -x node_modules/.bin/nest ] || npm ci --ignore-scripts --prefer-offline --no-audit --no-fund; npx nest build $*'
# Cargo runs INSIDE Docker (no rustc/cargo on the host). The registry and the
# per-workspace target dirs live in named volumes, so dependency downloads and
# incremental build state persist across runs while the host stays clean.
RUST_IMAGE          := public.ecr.aws/docker/library/rust:1.89-slim-bookworm
RUST_TOOLCHAIN_IMG  := mini-baas-rust-toolchain
CARGO_VOLS           = -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git
CARGO_DPR            = docker run --rm -v "$(PWD)/docker/services/data-plane-router":/work -w /work $(CARGO_VOLS) -v mini-baas-dpr-target:/work/target $(RUST_TOOLCHAIN_IMG)
CARGO_REALTIME       = docker run --rm -v "$(PWD)/docker/services/realtime/realtime-agnostic":/work -w /work $(CARGO_VOLS) -v mini-baas-realtime-target:/work/target $(RUST_TOOLCHAIN_IMG)

_rust-toolchain: ## (internal) cargo-in-docker image: rust + pkg-config/libssl (layer-cached)
	@printf 'FROM $(RUST_IMAGE)\nRUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' \
		| docker build -q -t $(RUST_TOOLCHAIN_IMG) - >/dev/null

rust-data-plane-check: _rust-toolchain ## Rust: cargo check the data-plane workspace (in Docker)
	@$(CARGO_DPR) cargo check --workspace
rust-data-plane-build: _rust-toolchain ## Rust: build the data-plane release binary (in Docker)
	@$(CARGO_DPR) cargo build --release --bin data-plane-router
rust-realtime-check: _rust-toolchain ## Rust: cargo check the realtime workspace (in Docker)
	@$(CARGO_REALTIME) cargo check --workspace
rust-realtime-test: _rust-toolchain ## Rust: run the realtime unit tests (in Docker)
	@$(CARGO_REALTIME) cargo test --workspace
rust-realtime-build: _rust-toolchain ## Rust: build the realtime-server release binary (in Docker)
	@$(CARGO_REALTIME) cargo build --release --bin realtime-server
go-control-plane-check: ## Go: vet + test the control-plane module (in Docker, cached modules)
	@docker run --rm -v "$(PWD)/go/control-plane":/src -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		golang:1.23-bookworm sh -c 'GOFLAGS=-mod=mod go vet ./... && GOFLAGS=-mod=mod go test ./...'
go-control-plane-build: ## Go: build the control-plane images
	@$(DC) --profile go-control-plane build

# ========================================================================== #
##@ Ops
# ========================================================================== #
preflight: ## Run pre-deployment checks
	@bash scripts/preflight-check.sh
hooks: ## Activate git hooks
	@if [ -d .git ]; then git config --local core.hooksPath $(HOOKS_DIR); chmod +x $(HOOKS_DIR)/* 2>/dev/null || true; echo -e "  $(_G)✓$(_0) hooks → $(HOOKS_DIR)"; else echo "  • not a git repo"; fi
update: ## Update git submodules
	@git submodule update --remote --merge && echo -e "$(_G)✓ Submodules updated$(_0)"

legacy-%: ## Run any target from the preserved Makefile.legacy
	@$(MAKE) -f Makefile.legacy $*

# ========================================================================== #
##@ Help
# ========================================================================== #
help: ## Show this help
	@echo ""
	@echo -e "$(_W)$(_C)$(PROJECT) — layer/edition orchestrator$(_0)"
	@echo -e "$(_D)EDITION=$(EDITION)  ·  make planes  ·  make editions  ·  make doctor$(_0)"
	@awk 'BEGIN {FS=":.*##"} \
		/^##@/ { printf "\n$(_W)%s$(_0)\n", substr($$0,5) } \
		/^[a-zA-Z0-9_%.-]+:.*##/ { printf "  $(_G)%-22s$(_0) $(_D)%s$(_0)\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo -e "$(_D)Generated per-plane verbs: up-<plane> down-<plane> restart-<plane> logs-<plane>$(_0)"
	@echo ""

.PHONY: all all-full clean fclean re up down restart ps logs pull build health \
        bench-startup observe planes editions doctor tests test-postgres \
        verify-all parity waf-test migrate migrate-mongo migrate-mysql migrate-all \
        migrate-status seed-mongo seed-live-demo secrets secrets-validate secrets-rotate \
        check-secrets env vault-init vault-status vault-rotate nestjs-ci \
        rust-data-plane-check rust-data-plane-build go-control-plane-check \
        rust-realtime-check rust-realtime-test rust-realtime-build _rust-toolchain \
        go-control-plane-build preflight hooks update help \
        _require-docker _require-compose _rm-stale
