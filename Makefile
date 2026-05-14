# Makefile for managing mini-Baas infrastructure images and environment.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
COMPOSE_PROGRESS ?= plain
BUILDKIT_PROGRESS ?= plain
BUILDX_BUILDER ?= default
BUILDX_IMAGE ?= moby/buildkit:buildx-stable-1
BUILDX_BOOTSTRAP_TIMEOUT ?= 120
BUILDX_BOOTSTRAP_KILL_AFTER ?= 15
DOCKER_BUILDKIT ?= 1
COMPOSE_DOCKER_CLI_BUILD ?= 1
COMPOSE_BAKE ?= 1
REGISTRY_CACHE_PREFIX ?=
BAKE_FILE ?= docker-bake.hcl
BAKE_GROUP ?= default
BAKE_TARGETS ?= postgres kong osionos-app mail calendar opposite-osiris-node
TRACK_BINOCLE_BIND_ADDR ?= $(shell if [ -r /sys/class/dmi/id/product_name ] && grep -qi 'VirtualBox' /sys/class/dmi/id/product_name 2>/dev/null && ip route 2>/dev/null | grep -q 'default via 10\.0\.2\.2'; then printf '0.0.0.0'; else printf '127.0.0.1'; fi)
export COMPOSE_PROGRESS BUILDKIT_PROGRESS BUILDX_BUILDER DOCKER_BUILDKIT COMPOSE_DOCKER_CLI_BUILD COMPOSE_BAKE REGISTRY_CACHE_PREFIX TRACK_BINOCLE_BIND_ADDR
DOCKER_PULL_ATTEMPTS ?= 1
DOCKER_PULL_TIMEOUT ?= 120
DOCKER_PULL_KILL_AFTER ?= 15
DOCKER_PREFETCH_JOBS ?= 8
DOCKER_PREFETCH_SCOPE ?= all
COMPOSE_WAIT_TIMEOUT ?= 300
COMPOSE_WAIT_INTERVAL ?= 2
COMPOSE_HEALTHY_SERVICES ?= postgres local-https-proxy mail-bridge mail pg-meta gotrue kong osionos-bridge osionos-app auth-gateway opposite-osiris calendar-bridge calendar
# supavisor restarts intermittently in CI, but the stack does not depend on it for readiness.
COMPOSE_RUNNING_SERVICES ?= redis postgrest mailpit
COMPOSE_COMPLETED_SERVICES ?= db-bootstrap project-db-init local-runtime-secrets opposite-osiris-deps
VERSION ?=
BAAS_VERSION ?= $(if $(VERSION),$(if $(filter v%,$(VERSION)),$(VERSION),v$(VERSION)),v$(shell date +%F))
APP_VERSION ?= $(if $(VERSION),$(if $(filter v%,$(VERSION)),$(VERSION),v$(VERSION)),v$(shell date +%F))
BAAS_DOCKERHUB_IMAGE ?= dlesieur/mini-baas-infra
BAAS_GHCR_IMAGE ?= ghcr.io/univers42/mini-baas-infra
BAAS_SMTP_IMAGE ?= dlesieur/mini-baas-infra
BAAS_SMTP_VERSION ?= smtp-v1
MAILPIT_IMAGE ?= axllent/mailpit:v1.22.3
BAAS_SERVICES ?= kong gotrue postgrest postgres redis realtime
BAAS_DOCKERFILE := apps/baas/Dockerfile
BAAS_CONTEXT := apps/baas
FRONTEND_DIR := apps/opposite-osiris
BOOL ?= false
WEBSITE_URL := https://localhost:4322
OSIONOS_URL := https://localhost:3001
BRIDGE_URL := https://localhost:4000
AUTH_URL := https://localhost:8787/api/auth
BAAS_URL := https://localhost:8000
MAIL_URL := https://localhost:3002
MAIL_BRIDGE_URL := https://localhost:4100
CALENDAR_URL := https://localhost:3003
CALENDAR_BRIDGE_URL := https://localhost:4200
VAULT_URL := https://localhost:18200
MAILPIT_URL := http://localhost:8025
PLAYGROUND_VIEWER_URL := $(OSIONOS_URL)/playground-simulation/index.html
VSCODE_CLI ?= /usr/bin/code
GIT_COMMIT_MESSAGE ?= update
GIT_PUSH_REMOTE ?= origin
LOCAL_CERT_DIR ?= apps/baas/certs
LOCAL_CA_CERT := $(LOCAL_CERT_DIR)/track-binocle-local-ca.pem
CERT_TRUST_MODE ?= system
CURL_HEALTH := curl --cacert $(LOCAL_CA_CERT) --retry 30 --retry-delay 2 --retry-all-errors --retry-connrefused -fsS
VAULT_COMPOSE := docker compose --profile secrets
VAULT_ENV_CMD := $(VAULT_COMPOSE) run --rm vault-env node apps/baas/scripts/vault-env.mjs
VAULT_SHARED_CMD := $(VAULT_COMPOSE) run --rm --no-deps
VAULT_TEAM_ROLE ?= reader
VAULT_TOKEN_TTL ?= 24h
VAULT_TEAM_TOKEN_FILE ?= .vault/track-binocle-$(VAULT_TEAM_ROLE).env
VAULT_READER_TOKEN_FILE ?= .vault/track-binocle-reader.env
VAULT_WRITER_TOKEN_FILE ?= .vault/track-binocle-writer.env
VAULT_TOKEN_FILE ?= $(VAULT_READER_TOKEN_FILE)
VAULT_PUBLISH_TOKEN_FILE ?= $(VAULT_WRITER_TOKEN_FILE)
VAULT_PUBLIC_ADDR ?= $(VAULT_URL)
VAULT_ENV_PREFIX ?= secret/data/track-binocle/env
VAULT_SHARED_REQUIRED ?= false
VAULT_SHARED_ADDR ?= $(FLY_VAULT_URL)
VAULT_ALLOW_LOCAL_SHARED ?= false
VAULT_UP_STAMP := .vault/.up-stamp
VAULT_GITHUB_OIDC_AUTH_PATH ?= jwt
VAULT_GITHUB_OIDC_ROLE ?= track-binocle-github-actions
VAULT_GITHUB_OIDC_REPOSITORY ?= Univers42/track-binocle
VAULT_GITHUB_OIDC_AUDIENCE ?= vault://track-binocle
VAULT_GITHUB_AUTH_PATH ?= github
VAULT_GITHUB_ORG ?= Univers42
VAULT_GITHUB_TEAM ?= transcendance
FLY_VAULT_APP ?= track-binocle-vault
FLY_VAULT_REGION ?= cdg
FLY_VAULT_VOLUME ?= vault_data
FLY_VAULT_URL ?= https://$(FLY_VAULT_APP).fly.dev
FLY ?= $(shell if command -v flyctl >/dev/null 2>&1; then command -v flyctl; elif command -v fly >/dev/null 2>&1; then command -v fly; else printf flyctl; fi)
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
export HOST_UID HOST_GID
NODE_BIN ?= $(shell command -v node 2>/dev/null || true)
DOCKER_NODE := docker run --rm --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -v "$$PWD":/workspace -w /workspace node:22-alpine
DOCKER_NODE_SHARED := docker run --rm --network host --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -e VAULT_ADDR -e VAULT_TOKEN -e VAULT_ENV_PREFIX -e NODE_EXTRA_CA_CERTS=/workspace/apps/baas/certs/track-binocle-local-ca.pem -v "$$PWD":/workspace -w /workspace node:22-alpine
DOCKER_NODE_VAULT := docker run --rm --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -e VAULT_ADDR -e VAULT_TOKEN -e VAULT_ENV_PREFIX -e VAULT_TEAM_ROLE -e VAULT_TOKEN_TTL -e VAULT_TEAM_TOKEN_FILE -e VAULT_PUBLIC_ADDR -e VAULT_GITHUB_OIDC_AUTH_PATH -e VAULT_GITHUB_OIDC_ROLE -e VAULT_GITHUB_OIDC_REPOSITORY -e VAULT_GITHUB_OIDC_AUDIENCE -e VAULT_GITHUB_AUTH_PATH -e VAULT_GITHUB_ORG -e VAULT_GITHUB_TEAM -v "$$PWD":/workspace -w /workspace node:22-alpine
NODE_RUN := $(if $(NODE_BIN),$(NODE_BIN),$(DOCKER_NODE) node)
NODE_RUN_SHARED := $(if $(NODE_BIN),$(NODE_BIN),$(DOCKER_NODE_SHARED) node)


# Beautiful help as the default target
.DEFAULT_GOAL := help


help:
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;39m        Track Binocle: Makefile Pipeline & Utilities         \033[0m"
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@printf "\033[1;38;5;45mUsage:\033[0m make [target]\n\n"
	@awk 'BEGIN { section = "" } /^[a-zA-Z0-9][^: ]*:/ { target=$$1; sub(":.*", "", target); getline; if ($$0 ~ /^## /) { desc = substr($$0, 4); if (desc ~ /^== /) { section = substr(desc, 4); printf("\n\033[1;38;5;220m%s\033[0m\n", section); } else { printf("  \033[1;38;5;81m%-22s\033[0m %s\n", target, desc); } } }' $(MAKEFILE_LIST)
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;245mFor docs: make docs or see README.md\033[0m"

all: env-fetch-shared pulls certs certs-trust-local certs-trust-browser-host bootstrap env-format docker-prefetch-images vault-seed vault-verify-approles env-fetch up healthcheck showcase
## Build, start, and verify the complete Vault-backed Track Binocle pipeline.

all-local: pulls certs certs-trust-local certs-trust-browser-host bootstrap env-format docker-prefetch-images vault-seed vault-verify-approles env-fetch up healthcheck showcase
## Build the local generated-secret pipeline without shared Vault credentials.

pulls:
## Fetch and pull the root repo plus every recursive submodule using configured upstreams.
	@set -eu; \
	echo '[pulls] root'; \
	git fetch --all --prune; \
	if git symbolic-ref --short -q HEAD >/dev/null && git rev-parse --verify --quiet '@{u}' >/dev/null; then \
		git pull --rebase --autostash; \
	else \
		echo '[pulls] root has no upstream branch; fetched only'; \
	fi; \
	git submodule sync --recursive; \
	git submodule update --init --recursive; \
	git submodule foreach --recursive ' \
		set -eu; \
		branch=$$(git symbolic-ref --short -q HEAD || true); \
		echo "[pulls] $${displaypath} ($${branch:-detached})"; \
		git fetch --all --prune; \
		if [ -n "$$branch" ] && git rev-parse --verify --quiet "@{u}" >/dev/null; then \
			git pull --rebase --autostash; \
		else \
			echo "[pulls] $${displaypath} has no upstream branch; fetched only"; \
		fi \
	'; \
	git submodule update --init --recursive --checkout

pushes:
## Add, commit, and push the root repo plus every recursive submodule. Use GIT_COMMIT_MESSAGE="...".
	@set -eu; \
	git submodule sync --recursive; \
	git submodule update --init --recursive; \
	repos="$$(git submodule foreach --quiet --recursive 'printf "%s\n" "$$displaypath"' | awk '{ print length, $$0 }' | sort -rn | cut -d' ' -f2-)"; \
	printf '%s\n.\n' "$$repos" | while IFS= read -r repo; do \
		[ -n "$$repo" ] || continue; \
		if ! git -C "$$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then continue; fi; \
		branch="$$(git -C "$$repo" symbolic-ref --short -q HEAD || true)"; \
		if [ -z "$$branch" ]; then echo "[pushes] $$repo is detached; skipping push"; continue; fi; \
		echo "[pushes] $$repo ($$branch)"; \
		git -C "$$repo" add -A; \
		if ! git -C "$$repo" diff --cached --quiet; then \
			git -C "$$repo" commit -m '$(GIT_COMMIT_MESSAGE)'; \
		else \
			echo "[pushes] $$repo has no staged changes"; \
		fi; \
		if git -C "$$repo" rev-parse --verify --quiet '@{u}' >/dev/null; then \
			git -C "$$repo" push; \
		else \
			git -C "$$repo" push -u '$(GIT_PUSH_REMOTE)' "$$branch"; \
		fi; \
	done

bootstrap:
	$(NODE_RUN) apps/baas/scripts/bootstrap.mjs

certs:
## Generate the local HTTPS CA and localhost certificate used by the Docker TLS proxy.
	bash apps/baas/scripts/generate-localhost-cert.sh

certs-trust: certs
## Trust the local HTTPS CA in user browser stores; use EXTRA_ARGS=--system for the Linux system store.
	bash apps/baas/scripts/trust-localhost-cert.sh $(EXTRA_ARGS)

certs-trust-system: certs
## Trust the local HTTPS CA in the Linux system store for VS Code/Electron and system-trust browsers.
	bash apps/baas/scripts/trust-localhost-cert.sh --system

certs-trust-browser-host: certs
## Copy and trust the local HTTPS CA on the forwarded browser host over SSH/SCP when reachable.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser-host trust import in CI/noninteractive mode'; \
	else \
		bash apps/baas/scripts/trust-browser-host-ca.sh; \
	fi

certs-doctor: certs
## Check whether the local trust stores and running HTTPS proxy use the current local HTTPS CA.
	@bash apps/baas/scripts/trust-localhost-cert.sh --verify || true
	@if docker compose ps --status running --quiet local-https-proxy 2>/dev/null | grep -q .; then \
		port="$${OPPOSITE_OSIRIS_HOST_PORT:-4322}"; \
		tmp_cert="$$(mktemp)"; \
		if timeout 5 openssl s_client -connect "localhost:$$port" -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$$tmp_cert" 2>/dev/null \
			&& openssl verify -CAfile '$(LOCAL_CA_CERT)' "$$tmp_cert" >/dev/null 2>&1; then \
			echo "[certs] local HTTPS proxy serves the current Track Binocle CA on https://localhost:$$port"; \
		else \
			echo "[certs] local HTTPS proxy certificate on https://localhost:$$port does not verify against $(LOCAL_CA_CERT); recreate local-https-proxy with make up." >&2; \
			exit 1; \
		fi; \
		redirect_status="$$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$$port/" || true)"; \
		if [[ "$$redirect_status" =~ ^30(1|7|8)$$ ]]; then \
			echo "[certs] plain HTTP on localhost:$$port redirects to HTTPS"; \
		else \
			echo "[certs] expected plain HTTP on localhost:$$port to redirect to HTTPS, got HTTP $$redirect_status" >&2; \
			exit 1; \
		fi; \
		rm -f "$$tmp_cert"; \
	else \
		echo '[certs] local-https-proxy is not running; skipping live proxy certificate check'; \
	fi

certs-trust-local: certs
## Trust the local HTTPS CA for developer browsers and system-trust clients; skipped in CI.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser trust import in CI/noninteractive mode'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'skip' ]]; then \
		echo '[certs] skipping local CA trust import because TRACK_BINOCLE_CERT_TRUST=skip'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'browser' ]]; then \
		bash apps/baas/scripts/trust-localhost-cert.sh; \
	elif [[ -t 0 || -t 1 ]] || { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }; then \
		bash apps/baas/scripts/trust-localhost-cert.sh --system; \
	else \
		echo '[certs] cannot update the system CA store without an interactive terminal or cached sudo.' >&2; \
		echo '[certs] Rerun make all from a terminal, run make certs-trust-system, or set TRACK_BINOCLE_CERT_TRUST=browser/skip intentionally.' >&2; \
		exit 1; \
	fi

env-format:
	$(NODE_RUN) apps/baas/scripts/vault-env.mjs format

buildx-setup:
## Ensure a BuildKit docker-container builder is available for parallel bake builds.
	@set -eu; \
	if docker buildx inspect '$(BUILDX_BUILDER)' >/dev/null 2>&1; then \
		docker buildx use '$(BUILDX_BUILDER)' >/dev/null; \
	else \
		docker buildx create --name '$(BUILDX_BUILDER)' --driver docker-container --driver-opt image='$(BUILDX_IMAGE)' --use >/dev/null; \
	fi; \
	if ! timeout --kill-after='$(BUILDX_BOOTSTRAP_KILL_AFTER)s' '$(BUILDX_BOOTSTRAP_TIMEOUT)s' docker buildx inspect --bootstrap '$(BUILDX_BUILDER)' >/dev/null; then \
		echo '[docker] recreating unresponsive buildx builder $(BUILDX_BUILDER)'; \
		docker buildx rm -f '$(BUILDX_BUILDER)' >/dev/null 2>&1 || true; \
		docker buildx create --name '$(BUILDX_BUILDER)' --driver docker-container --driver-opt image='$(BUILDX_IMAGE)' --use >/dev/null; \
		timeout --kill-after='$(BUILDX_BOOTSTRAP_KILL_AFTER)s' '$(BUILDX_BOOTSTRAP_TIMEOUT)s' docker buildx inspect --bootstrap '$(BUILDX_BUILDER)' >/dev/null; \
	fi

compose-build: buildx-setup
## Build local Compose images in parallel with BuildKit bake and optional registry cache.
	@set -eu; \
	cache_flags=''; \
	if [[ -n '$(REGISTRY_CACHE_PREFIX)' ]]; then \
		echo '[docker] using registry build cache $(REGISTRY_CACHE_PREFIX)'; \
		for target in $(BAKE_TARGETS); do \
			cache_ref='$(REGISTRY_CACHE_PREFIX)'"/$$target"; \
			cache_flags="$$cache_flags --set $$target.cache-from=type=registry,ref=$$cache_ref"; \
			cache_flags="$$cache_flags --set $$target.cache-to=type=registry,ref=$$cache_ref,mode=max"; \
		done; \
	fi; \
	docker buildx bake --builder '$(BUILDX_BUILDER)' --file '$(BAKE_FILE)' --load $$cache_flags '$(BAKE_GROUP)'

docker-prefetch-images:
## Pull required public images from resilient mirrors before Compose builds.
	@set -eu; \
	jobs='$(DOCKER_PREFETCH_JOBS)'; \
	scope='$(DOCKER_PREFETCH_SCOPE)'; \
	case "$$jobs" in ''|*[!0-9]*) echo '[docker] DOCKER_PREFETCH_JOBS must be a positive integer'; exit 1;; esac; \
	case "$$scope" in all|vault) ;; *) echo '[docker] DOCKER_PREFETCH_SCOPE must be all or vault'; exit 1;; esac; \
	if [ "$$jobs" -lt 1 ]; then jobs=1; fi; \
	echo "[docker] prefetching $$scope images with up to $$jobs concurrent pulls"; \
	pull_image() { \
		target="$$1"; shift; \
		if docker image inspect "$$target" >/dev/null 2>&1; then echo "[docker] using cached $$target"; return 0; fi; \
		refs="$$* $$target"; \
		for ref in $$refs; do \
			attempt=1; \
			while [ "$$attempt" -le '$(DOCKER_PULL_ATTEMPTS)' ]; do \
				echo "[docker] pulling $$ref for $$target (attempt $$attempt/$(DOCKER_PULL_ATTEMPTS), timeout $(DOCKER_PULL_TIMEOUT)s)"; \
				if timeout --kill-after='$(DOCKER_PULL_KILL_AFTER)s' '$(DOCKER_PULL_TIMEOUT)s' docker pull -q "$$ref" >/dev/null; then \
					if [ "$$ref" != "$$target" ]; then docker tag "$$ref" "$$target" >/dev/null; fi; \
					echo "[docker] ready $$target"; \
					return 0; \
				fi; \
				attempt=$$((attempt + 1)); \
			done; \
		done; \
		echo "[docker] failed to pull $$target"; return 1; \
	}; \
	failed=0; \
	wait_for_pull() { \
		set +e; wait -n; status="$$?"; set -e; \
		if [ "$$status" -ne 0 ] && [ "$$status" -ne 127 ]; then failed=1; fi; \
	}; \
	start_pull() { \
		pull_image "$$@" & \
		while [ "$$(jobs -pr | wc -l)" -ge "$$jobs" ]; do wait_for_pull; done; \
	}; \
	start_pull public.ecr.aws/docker/library/node:22-alpine; \
	start_pull public.ecr.aws/docker/library/nginx:1.27-alpine; \
	start_pull docker/dockerfile:1; \
	start_pull docker/dockerfile:1.7; \
	start_pull public.ecr.aws/hashicorp/vault:1.16; \
	if [[ "$$scope" == 'all' ]]; then \
		start_pull public.ecr.aws/docker/library/node:22-bookworm-slim; \
		start_pull public.ecr.aws/docker/library/postgres:16-alpine; \
		start_pull public.ecr.aws/docker/library/redis:7-alpine; \
		start_pull '$(MAILPIT_IMAGE)'; \
		start_pull public.ecr.aws/docker/library/kong:3.8; \
		start_pull mirror.gcr.io/postgrest/postgrest:v12.2.3; \
		start_pull public.ecr.aws/supabase/gotrue:v2.188.1; \
		start_pull public.ecr.aws/supabase/postgres-meta:v0.91.0; \
	fi; \
	while [ "$$(jobs -p | wc -l)" -gt 0 ]; do wait_for_pull; done; \
	if [ "$$failed" -ne 0 ]; then echo '[docker] one or more image pulls failed'; exit 1; fi

vault-up: certs
	@mkdir -p .vault
	@if [ -f $(VAULT_UP_STAMP) ] && $(VAULT_COMPOSE) ps --status running --quiet vault 2>/dev/null | grep -q .; then \
		echo '[vault] already up, skipping init'; \
	else \
		$(MAKE) docker-prefetch-images DOCKER_PREFETCH_SCOPE=vault; \
		$(MAKE) compose-build BAKE_GROUP=secrets BAKE_TARGETS='vault'; \
		docker compose rm -sf local-https-proxy >/dev/null 2>&1 || true; \
		$(VAULT_COMPOSE) up -d --no-build --pull never vault local-https-proxy; \
		$(VAULT_COMPOSE) run --rm vault-init; \
		touch $(VAULT_UP_STAMP); \
	fi

vault-seed: vault-up
	$(VAULT_ENV_CMD) seed

vault-publish: vault-up
## Publish the current managed local env files into Vault without printing values.
	$(VAULT_ENV_CMD) publish

vault-status: vault-up
## Compare local and Vault managed env key coverage without printing secret values.
	$(VAULT_ENV_CMD) status

vault-policy-sync: vault-up
## Sync limited reader/writer policies for invited team secret access.
	$(VAULT_ENV_CMD) sync-policies

vault-invite-token: vault-policy-sync
## Create an ignored .vault invite token file. Use VAULT_TEAM_ROLE=reader|writer.
	$(VAULT_COMPOSE) run --rm -e VAULT_TEAM_ROLE='$(VAULT_TEAM_ROLE)' -e VAULT_TOKEN_TTL='$(VAULT_TOKEN_TTL)' -e VAULT_TEAM_TOKEN_FILE='$(VAULT_TEAM_TOKEN_FILE)' -e VAULT_PUBLIC_ADDR='$(VAULT_PUBLIC_ADDR)' vault-env node apps/baas/scripts/vault-env.mjs team-token

vault-fly-invite-token:
## Create an ignored .vault invite token file from the Fly-hosted Vault.
	@mkdir -p .vault
	@set -eu; token_file='.vault/fly-vault-root-token'; trap 'rm -f "$$token_file"' EXIT; \
		$(FLY) ssh console --app $(FLY_VAULT_APP) --command 'jq -r .root_token /vault/data/.vault-keys.json' > "$$token_file"; \
		chmod 600 "$$token_file"; \
		token="$$(tr -d '\r\n' < "$$token_file")"; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_TOKEN="$$token" VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_TEAM_ROLE='$(VAULT_TEAM_ROLE)' VAULT_TOKEN_TTL='$(VAULT_TOKEN_TTL)' VAULT_TEAM_TOKEN_FILE='$(VAULT_TEAM_TOKEN_FILE)' VAULT_PUBLIC_ADDR='$(FLY_VAULT_URL)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs team-token

vault-fetch-shared:
## Fetch managed env files with VAULT_API_KEY, VAULT_TOKEN, or VAULT_TOKEN_FILE from an invited user.
	@set -eu; \
	token_file='$(VAULT_TOKEN_FILE)'; \
	token_source='none'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
		token_source="file:$$token_file"; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
		token_source='VAULT_API_KEY'; \
		echo '[vault] using VAULT_API_KEY from the current shell environment'; \
	elif [[ -n "$${VAULT_TOKEN:-}" ]]; then \
		token_source='VAULT_TOKEN'; \
		echo '[vault] using VAULT_TOKEN from the current shell environment'; \
	fi; \
	if [[ "$$token_source" == 'none' && -z "$${VAULT_TOKEN:-}" ]]; then \
		echo '[vault] missing shared Vault token'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] install $(VAULT_TOKEN_FILE) under this root or export VAULT_API_KEY/VAULT_TOKEN'; \
		exit 1; \
	fi; \
	: "$${VAULT_TOKEN:?Set VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	if [[ -z "$${VAULT_ADDR:-}" ]]; then \
		VAULT_ADDR='$(VAULT_SHARED_ADDR)'; \
		export VAULT_ADDR; \
		echo '[vault] no VAULT_ADDR supplied; defaulting shared Vault fetch to $(VAULT_SHARED_ADDR)'; \
	fi; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	vault_addr_is_local=0; \
	case "$$VAULT_ADDR" in \
		https://local-https-proxy:*|http://local-https-proxy:*) \
			VAULT_ADDR="$${VAULT_ADDR/local-https-proxy/localhost}"; \
			export VAULT_ADDR; \
			vault_addr_is_local=1; \
			echo '[vault] translated Docker-only Vault host local-https-proxy to localhost for host fetch'; \
			;; \
		https://localhost:*|http://localhost:*|https://127.0.0.1:*|http://127.0.0.1:*) \
			vault_addr_is_local=1; \
			;; \
	esac; \
	if [[ "$$vault_addr_is_local" == '1' ]]; then \
		if [[ '$(VAULT_ALLOW_LOCAL_SHARED)' == 'true' || '$(VAULT_ALLOW_LOCAL_SHARED)' == '1' ]]; then \
			echo '[vault] local shared fetch explicitly allowed; ensuring local Vault proxy is running'; \
			$(MAKE) vault-up; \
		else \
			echo '[vault] refusing localhost Vault address for shared env fetch.'; \
			echo '[vault] This token only works with the Vault instance on the machine that issued it.'; \
			echo '[vault] For a fresh VM or teammate machine, use a Fly-backed invite token:'; \
			echo '[vault]   maintainer: make vault-fly-invite-token VAULT_TEAM_ROLE=reader'; \
			echo '[vault]   teammate:   install .vault/track-binocle-reader.env, chmod 600 it, then make vault-shared-doctor'; \
			echo '[vault] If you have a bare Fly token, run: VAULT_API_KEY=... VAULT_ADDR=$(VAULT_SHARED_ADDR) make vault-fetch-shared'; \
			echo '[vault] For same-machine local token testing only, rerun with VAULT_ALLOW_LOCAL_SHARED=true.'; \
			exit 1; \
		fi; \
	fi; \
	if [[ -z "$${NODE_EXTRA_CA_CERTS:-}" && -f '$(LOCAL_CA_CERT)' ]]; then export NODE_EXTRA_CA_CERTS='$(LOCAL_CA_CERT)'; fi; \
	$(NODE_RUN_SHARED) apps/baas/scripts/vault-env.mjs fetch

vault-shared-doctor:
## Check shared Vault token wiring without printing secret values.
	@set -eu; \
	token_file='$(VAULT_TOKEN_FILE)'; \
	token_source='none'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
		token_source="file:$$token_file"; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
		token_source='VAULT_API_KEY'; \
	elif [[ -n "$${VAULT_TOKEN:-}" ]]; then \
		token_source='VAULT_TOKEN'; \
	fi; \
	if [[ "$$token_source" == 'none' ]]; then \
		echo '[vault] no shared Vault token found'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] install $(VAULT_TOKEN_FILE) under this root or export VAULT_API_KEY/VAULT_TOKEN'; \
		exit 1; \
	fi; \
	if [[ -z "$${VAULT_ADDR:-}" ]]; then \
		VAULT_ADDR='$(VAULT_SHARED_ADDR)'; \
		export VAULT_ADDR; \
		echo '[vault] no VAULT_ADDR supplied; defaulting to $(VAULT_SHARED_ADDR)'; \
	fi; \
	echo "[vault] token source: $$token_source"; \
	echo "[vault] vault address: $$VAULT_ADDR"; \
	echo "[vault] env prefix: $${VAULT_ENV_PREFIX:-$(VAULT_ENV_PREFIX)}"; \
	case "$$VAULT_ADDR" in \
		https://local-https-proxy:*|http://local-https-proxy:*|https://localhost:*|http://localhost:*|https://127.0.0.1:*|http://127.0.0.1:*) \
			if [[ '$(VAULT_ALLOW_LOCAL_SHARED)' == 'true' || '$(VAULT_ALLOW_LOCAL_SHARED)' == '1' ]]; then \
				echo '[vault] localhost Vault allowed for same-machine testing'; \
			else \
				echo '[vault] problem: localhost Vault tokens are not portable to a fresh VM or teammate machine'; \
				echo '[vault] fix: replace this token with one generated by make vault-fly-invite-token'; \
				exit 1; \
			fi; \
			;; \
		*) \
			echo '[vault] shared Vault token wiring looks usable'; \
			;; \
	esac

env-fetch-shared:
## Fetch shared team secrets first when a reader/writer token is available.
	@set -eu; \
	if [[ -f '$(VAULT_TOKEN_FILE)' || -n "$${VAULT_API_KEY:-}" || -n "$${VAULT_TOKEN:-}" ]]; then \
		if $(MAKE) vault-fetch-shared VAULT_TOKEN_FILE='$(VAULT_TOKEN_FILE)'; then \
			echo '[vault] shared env fetch complete'; \
		elif [[ '$(VAULT_SHARED_REQUIRED)' == 'true' || '$(VAULT_SHARED_REQUIRED)' == '1' || "$${GITHUB_ACTIONS:-}" == 'true' ]]; then \
			exit 1; \
		else \
			echo '[vault] shared env fetch failed; continuing with local generated development secrets'; \
			echo '[vault] set VAULT_SHARED_REQUIRED=true to make shared Vault failures fatal'; \
		fi; \
	elif [[ "$${GITHUB_ACTIONS:-}" == 'true' ]]; then \
		echo '[vault] GitHub Actions must use its OIDC-generated Vault token file before make all.'; \
		exit 1; \
	elif [[ '$(VAULT_SHARED_REQUIRED)' == 'true' || '$(VAULT_SHARED_REQUIRED)' == '1' ]]; then \
		echo '[vault] missing shared Vault credentials. Set VAULT_API_KEY+VAULT_ADDR, VAULT_TOKEN+VAULT_ADDR, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE).'; \
		exit 1; \
	else \
		echo '[vault] missing shared Vault credentials; continuing with local generated development secrets'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] set VAULT_SHARED_REQUIRED=true to make this fatal'; \
	fi

vault-publish-shared:
## Publish managed env files with a writer VAULT_API_KEY, VAULT_TOKEN, or token file.
	@set -eu; \
	token_file='$(VAULT_PUBLISH_TOKEN_FILE)'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
	elif [[ -f '$(VAULT_TOKEN_FILE)' ]]; then \
		mode="$$(stat -c '%a' '$(VAULT_TOKEN_FILE)')"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $(VAULT_TOKEN_FILE) because it must be private; run: chmod 600 $(VAULT_TOKEN_FILE)"; exit 1;; esac; \
		set -a; . '$(VAULT_TOKEN_FILE)'; set +a; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
	fi; \
	: "$${VAULT_TOKEN:?Set a writer VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_PUBLISH_TOKEN_FILE=$(VAULT_PUBLISH_TOKEN_FILE)}"; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE}"; \
	$(VAULT_SHARED_CMD) -e VAULT_TOKEN -e VAULT_ADDR -e VAULT_ENV_PREFIX vault-env node apps/baas/scripts/vault-env.mjs publish

vault-status-shared:
## Check managed Vault env coverage with an invited reader/writer API key or token.
	@set -eu; \
	if [[ -f '$(VAULT_TOKEN_FILE)' ]]; then \
		mode="$$(stat -c '%a' '$(VAULT_TOKEN_FILE)')"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $(VAULT_TOKEN_FILE) because it must be private; run: chmod 600 $(VAULT_TOKEN_FILE)"; exit 1;; esac; \
		set -a; . '$(VAULT_TOKEN_FILE)'; set +a; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
	fi; \
	: "$${VAULT_TOKEN:?Set VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	$(VAULT_SHARED_CMD) -e VAULT_TOKEN -e VAULT_ADDR -e VAULT_ENV_PREFIX vault-env node apps/baas/scripts/vault-env.mjs status

vault-repair-shared: env-format
## Publish complete local env files to shared Vault with a writer token, then verify coverage.
	$(MAKE) vault-publish-shared VAULT_PUBLISH_TOKEN_FILE='$(VAULT_PUBLISH_TOKEN_FILE)' VAULT_TOKEN_FILE='$(VAULT_TOKEN_FILE)'
	$(MAKE) vault-status-shared VAULT_TOKEN_FILE='$(VAULT_PUBLISH_TOKEN_FILE)'

vault-github-oidc: vault-policy-sync
## Configure Vault JWT auth so GitHub Actions can fetch managed env secrets through OIDC.
	$(VAULT_COMPOSE) run --rm -e VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' -e VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' -e VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' -e VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' -e VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' -e VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' -e VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' vault-env node apps/baas/scripts/vault-env.mjs sync-github-oidc

vault-fly-create:
## Create the Fly app and persistent Vault volume when missing.
	@$(FLY) apps create $(FLY_VAULT_APP) --org personal || true
	@$(FLY) volumes list --app $(FLY_VAULT_APP) | grep -q '$(FLY_VAULT_VOLUME)' || $(FLY) volumes create $(FLY_VAULT_VOLUME) --app $(FLY_VAULT_APP) --region $(FLY_VAULT_REGION) --size 1 --yes

vault-fly-deploy:
## Deploy the public Vault service to Fly.io.
	@cd apps/baas/mini-baas-infra/docker/services/vault && $(FLY) deploy --app $(FLY_VAULT_APP) --config fly.toml --remote-only

vault-fly-publish:
## Publish managed env data and GitHub auth configuration to the Fly Vault.
	@mkdir -p .vault
	@set -eu; token_file='.vault/fly-vault-root-token'; trap 'rm -f "$$token_file"' EXIT; \
		$(FLY) ssh console --app $(FLY_VAULT_APP) --command 'jq -r .root_token /vault/data/.vault-keys.json' > "$$token_file"; \
		chmod 600 "$$token_file"; \
		token="$$(tr -d '\r\n' < "$$token_file")"; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_TOKEN="$$token" VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs publish; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_TOKEN="$$token" VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs sync-github-oidc

vault-fly-github:
## Point GitHub Actions at the public Fly Vault URL.
	@gh variable set TRACK_BINOCLE_VAULT_ADDR --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(FLY_VAULT_URL)'
	@gh variable set TRACK_BINOCLE_VAULT_AUTH_PATH --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_AUTH_PATH)'
	@gh variable set TRACK_BINOCLE_VAULT_ROLE --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_ROLE)'
	@gh variable set TRACK_BINOCLE_VAULT_ENV_PREFIX --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_ENV_PREFIX)'

vault-fly: vault-fly-create vault-fly-deploy vault-fly-publish vault-fly-github
## Create, deploy, publish, and wire GitHub Actions to the Fly-hosted Vault.

vault-rotate-approles: vault-up
## Rotate service AppRole secret IDs and store the new IDs in Vault.
	$(VAULT_ENV_CMD) rotate-approles

vault-verify-approles: vault-up
	$(VAULT_ENV_CMD) verify-approles

env-fetch: vault-up
	$(VAULT_ENV_CMD) fetch

env-backup:
	$(NODE_RUN) apps/baas/scripts/vault-env.mjs backup

env-restore-test: vault-seed
	$(VAULT_ENV_CMD) roundtrip

db-password-check:
## Verify apps/baas/.env.local matches the live Postgres password without printing it.
	@set -eu; set -a; . apps/baas/.env.local; set +a; \
	docker compose exec -T -e PGPASSWORD="$$POSTGRES_PASSWORD" postgres psql -h 127.0.0.1 -U "$${POSTGRES_USER:-postgres}" -d "$${POSTGRES_DB:-postgres}" -tAc 'select 1' >/dev/null; \
	echo 'postgres-password-ok'

db-password-apply:
## Apply POSTGRES_PASSWORD from apps/baas/.env.local to the live Postgres role.
	@set -eu; set -a; . apps/baas/.env.local; set +a; \
	docker compose exec -T -u postgres -e POSTGRES_TARGET_USER="$${POSTGRES_USER:-postgres}" -e POSTGRES_TARGET_PASSWORD="$$POSTGRES_PASSWORD" -e POSTGRES_TARGET_DB="$${POSTGRES_DB:-postgres}" postgres sh -s < apps/baas/scripts/sync-postgres-password.sh; \
	echo 'postgres-password-updated'

compose-wait:
## Wait for long-running services to become healthy/running and init jobs to exit cleanly.
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

up: certs docker-prefetch-images compose-build
## Build and start every service in the root Docker Compose graph.
	@docker compose kill local-https-proxy mailpit db-bootstrap project-db-init gotrue kong postgrest pg-meta supavisor osionos-bridge osionos-app auth-gateway opposite-osiris mail-bridge mail calendar-bridge calendar >/dev/null 2>&1 || true
	@docker compose rm -f local-https-proxy mailpit db-bootstrap project-db-init gotrue kong postgrest pg-meta supavisor osionos-bridge osionos-app auth-gateway opposite-osiris mail-bridge mail calendar-bridge calendar >/dev/null 2>&1 || true
	docker compose up -d --no-build --pull never --wait postgres
	$(MAKE) db-password-apply
	docker compose up -d --no-build --pull never
	$(MAKE) compose-wait

app-images:
## Build the local Docker images for the website, osionos, Mail, Calendar, bridges, and BaaS gateway.
	$(MAKE) compose-build BAKE_GROUP=testing BAKE_TARGETS='$(BAKE_TARGETS) playground-simulation'

app-login:
## Log in to DockerHub using DOCKER_USER/DOCKER_PAT from the shell or ignored env files.
	@set +u; set -a; \
	for env_file in .env.local .env apps/baas/mini-baas-infra/.env; do \
		if [[ -f "$$env_file" ]]; then . "$$env_file"; fi; \
	done; \
	set +a; set -u; \
	docker_user="$${DOCKER_USER:-$${DOCKER_LOGIN:-}}"; \
	docker_pat="$${DOCKER_PAT:-}"; \
	if [[ -z "$$docker_user" || -z "$$docker_pat" ]]; then \
		echo 'DOCKER_USER and DOCKER_PAT must be set in the shell or an ignored env file.'; \
		exit 1; \
	fi; \
	printf '%s' "$$docker_pat" | docker login docker.io -u "$$docker_user" --password-stdin >/dev/null; \
	echo 'dockerhub-login-ok'

app-images-push: app-images app-login
## Tag and push the application images to DockerHub. Use VERSION=vX.Y.Z to override the tag.
	@set +u; set -a; \
	for env_file in .env.local .env apps/baas/mini-baas-infra/.env; do \
		if [[ -f "$$env_file" ]]; then . "$$env_file"; fi; \
	done; \
	set +a; set -u; \
	docker_user="$${DOCKER_USER:-$${DOCKER_LOGIN:-}}"; \
	if [[ -z "$$docker_user" ]]; then \
		echo 'DOCKER_USER must be set in the shell or an ignored env file.'; \
		exit 1; \
	fi; \
	for spec in \
		'track-binocle/mini-baas-kong:local track-binocle-mini-baas-kong' \
		'track-binocle/osionos-app:local track-binocle-osionos-app' \
		'track-binocle/mail-bridge:local track-binocle-mail-bridge' \
		'track-binocle/mail:local track-binocle-mail' \
		'track-binocle/calendar-bridge:local track-binocle-calendar-bridge' \
		'track-binocle/calendar:local track-binocle-calendar' \
		'track-binocle/auth-gateway:local track-binocle-auth-gateway' \
		'track-binocle/opposite-osiris:local track-binocle-opposite-osiris' \
		'track-binocle/opposite-osiris-deps:local track-binocle-opposite-osiris-deps' \
		'track-binocle/playground-simulation:local track-binocle-playground-simulation'; do \
		set -- $$spec; \
		local_image="$$1"; \
		remote_repo="docker.io/$$docker_user/$$2"; \
		docker tag "$$local_image" "$$remote_repo:$(APP_VERSION)"; \
		docker tag "$$local_image" "$$remote_repo:latest"; \
		docker push "$$remote_repo:$(APP_VERSION)"; \
		docker push "$$remote_repo:latest"; \
		echo "pushed $$remote_repo:$(APP_VERSION) and latest"; \
	done

mail-up: docker-prefetch-images
## Start osionos Mail and the Gmail bridge with Docker Compose.
	$(MAKE) compose-build BAKE_GROUP=mail BAKE_TARGETS='mail'
	docker compose up -d --no-build --pull never mail mail-bridge

mail-logs:
## Follow osionos Mail and Gmail bridge logs.
	docker compose logs -f mail mail-bridge

mail-down:
## Stop osionos Mail and the Gmail bridge containers.
	docker compose stop mail mail-bridge

calendar-up: docker-prefetch-images
## Start osionos Calendar and the Google Calendar bridge with Docker Compose.
	$(MAKE) compose-build BAKE_GROUP=calendar BAKE_TARGETS='calendar'
	docker compose up -d --no-build --pull never calendar calendar-bridge

calendar-logs:
## Follow osionos Calendar and Google Calendar bridge logs.
	docker compose logs -f calendar calendar-bridge

calendar-down:
## Stop osionos Calendar and the Google Calendar bridge containers.
	docker compose stop calendar calendar-bridge

healthcheck: certs
## Verify the BaaS, website, osionos app, Mail, Calendar, bridges, and app-to-BaaS connectivity.
	docker compose ps
	$(CURL_HEALTH) $(BAAS_URL) >/dev/null
	$(CURL_HEALTH) $(BRIDGE_URL)/api/auth/bridge/health
	$(CURL_HEALTH) $(OSIONOS_URL) >/dev/null
	$(CURL_HEALTH) $(WEBSITE_URL) >/dev/null
	@redirect_status="$$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$${OPPOSITE_OSIRIS_HOST_PORT:-4322}/" || true)"; \
	if [[ "$$redirect_status" =~ ^30(1|7|8)$$ ]]; then \
		echo '[healthcheck] website plain HTTP redirects to HTTPS'; \
	else \
		echo "[healthcheck] expected website plain HTTP to redirect to HTTPS, got HTTP $$redirect_status" >&2; \
		exit 1; \
	fi
	$(CURL_HEALTH) -o /dev/null -w 'auth-gateway-https-%{http_code}\n' $(AUTH_URL)/availability
	$(CURL_HEALTH) $(MAILPIT_URL) >/dev/null
	docker compose exec -T auth-gateway node scripts/verify-newsletter-delivery.mjs
	$(CURL_HEALTH) $(MAIL_BRIDGE_URL)/health >/dev/null
	$(CURL_HEALTH) $(MAIL_URL) >/dev/null
	$(CURL_HEALTH) $(CALENDAR_BRIDGE_URL)/health >/dev/null
	$(CURL_HEALTH) $(CALENDAR_URL) >/dev/null
	docker compose exec -T mail-bridge node -e "fetch('http://127.0.0.1:' + (process.env.MAIL_BRIDGE_PORT || '4100') + '/session').then((r) => r.json()).then((session) => { if (!session.configured) console.warn('[healthcheck] Gmail OAuth credentials are not configured; Mail stays available with mock/local data, but Gmail connect and sync are disabled until this developer adds their own Google OAuth client credentials.'); }).catch((error) => { console.error(error.message); process.exit(1); })"
	docker compose exec -T calendar-bridge node -e "fetch('http://127.0.0.1:' + (process.env.CALENDAR_BRIDGE_PORT || '4200') + '/session').then((r) => r.json()).then((session) => { if (!session.configured) console.warn('[healthcheck] Google Calendar OAuth credentials are not configured; Calendar stays available, but Google Calendar connect and sync are disabled until this developer adds their own Google OAuth client credentials.'); }).catch((error) => { console.error(error.message); process.exit(1); })"
	docker compose exec -T calendar-bridge node -e "fetch('http://127.0.0.1:' + (process.env.CALENDAR_BRIDGE_PORT || '4200') + '/baas/status').then((r) => r.json()).then((status) => { if (!status.connected) { console.error('calendar bridge cannot reach the BaaS gateway'); process.exit(1); } }).catch((error) => { console.error(error.message); process.exit(1); })"
	docker compose exec -T -e BAAS_INTERNAL_URL=http://kong:8000 opposite-osiris node scripts/container-only.mjs node scripts/verify-connection.mjs

showcase:
## Print the local service URLs after the pipeline is healthy.
	@printf '\nPipeline ready. Open these local services:\n'
	@printf '  Website:             %s\n' '$(WEBSITE_URL)'
	@printf '  osionos app:         %s\n' '$(OSIONOS_URL)'
	@printf '  osionos bridge API:  %s\n' '$(BRIDGE_URL)'
	@printf '  Auth gateway:        %s\n' '$(AUTH_URL)'
	@printf '  BaaS gateway:        %s\n\n' '$(BAAS_URL)'
	@printf '  Vault:               %s\n\n' '$(VAULT_URL)'
	@printf '  Local mail inbox:    %s\n\n' '$(MAILPIT_URL)'
	@printf '  osionos Mail:        %s\n' '$(MAIL_URL)'
	@printf '  Mail bridge:         %s\n' '$(MAIL_BRIDGE_URL)'
	@printf '  osionos Calendar:    %s\n' '$(CALENDAR_URL)'
	@printf '  Calendar bridge:     %s\n\n' '$(CALENDAR_BRIDGE_URL)'
	@if [[ -n "$${SSH_CONNECTION:-}" || -n "$${VSCODE_IPC_HOOK_CLI:-}" || -n "$${VSCODE_GIT_IPC_HANDLE:-}" ]]; then \
		printf '[certs] Remote/forwarded browser note: if your browser opens a random forwarded URL such as https://localhost:<port>, it is running outside this VM.\n'; \
		printf '[certs] Firefox note: prefer the canonical URLs printed above when reachable; if VS Code remaps to another port, close and reopen that forwarded port after certificate regeneration.\n'; \
		printf '[certs] make certs-trust-browser-host tries SSH/SCP CA trust for that browser host; see docs/troubleshoot/browser-host-ca-trust.md if SSH is blocked.\n\n'; \
	fi

playground: healthcheck playground-preview
## Run the Docker Playwright user flow and app-service integration simulation.
	$(MAKE) compose-build BAKE_GROUP=playground BAKE_TARGETS='playground-simulation'
	docker compose --profile testing run --rm playground-simulation
	$(MAKE) showcase

playground-preview:
## Open the VS Code simulation viewer for Docker Playwright results.
	@printf '\nSimulation preview: Docker Playwright will create a throwaway account and bridge it into osionos.\n'
	@printf 'Opening the VS Code simulation viewer: %s\n' '$(PLAYGROUND_VIEWER_URL)'
	@if [ -x '$(VSCODE_CLI)' ]; then \
		'$(VSCODE_CLI)' --reuse-window '$(PLAYGROUND_VIEWER_URL)' >/dev/null 2>&1 || printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	else \
		printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	fi

docs:
## Show the primary Docker pipeline documentation files.
	@printf 'Read README.md and docs/howtouse.md for the Docker-only pipeline workflow.\n'

version: baas-update baas-build baas-push baas-smoke
## Publish a versioned BaaS release to DockerHub and GHCR, then smoke-test it.
	@echo "Published mini-baas-infra $(BAAS_VERSION) to DockerHub and GHCR."

baas-build:
## Tag the locally built composable mini-baas images with versioned and latest tags.
	@for service in $(BAAS_SERVICES); do \
		source="$(BAAS_DOCKERHUB_IMAGE)-$$service:latest"; \
		if [ "$$service" = "realtime" ] && ! docker image inspect "$$source" >/dev/null 2>&1; then source="dlesieur/realtime-agnostic:latest"; fi; \
		docker image inspect "$$source" >/dev/null; \
		docker tag "$$source" "$(BAAS_DOCKERHUB_IMAGE)-$$service:$(BAAS_VERSION)"; \
		docker tag "$$source" "$(BAAS_DOCKERHUB_IMAGE)-$$service:latest"; \
		docker tag "$$source" "$(BAAS_GHCR_IMAGE)/$$service:$(BAAS_VERSION)"; \
		docker tag "$$source" "$(BAAS_GHCR_IMAGE)/$$service:latest"; \
		echo "Tagged $$service as $(BAAS_VERSION) and latest for DockerHub/GHCR"; \
	done

baas-push:
## Push both DockerHub and GHCR version/latest aliases for every BaaS service image.
	@for service in $(BAAS_SERVICES); do \
		docker push "$(BAAS_DOCKERHUB_IMAGE)-$$service:$(BAAS_VERSION)"; \
		docker push "$(BAAS_DOCKERHUB_IMAGE)-$$service:latest"; \
		docker push "$(BAAS_GHCR_IMAGE)/$$service:$(BAAS_VERSION)"; \
		docker push "$(BAAS_GHCR_IMAGE)/$$service:latest"; \
	done

baas-update:
# Pin the wrapper Dockerfile to the versioned image tag, never latest.
	python3 -c "from pathlib import Path; path=Path('$(BAAS_DOCKERFILE)'); version='$(BAAS_VERSION)'; image='$(BAAS_DOCKERHUB_IMAGE)-kong'; lines=path.read_text().splitlines(); idx=next((i for i,line in enumerate(lines) if line.startswith('FROM ')), None); assert idx is not None, f'No FROM line found in {path}'; lines[idx]=f'FROM {image}:{version}'; path.write_text('\\n'.join(lines) + '\\n'); print(f'Pinned {path} to {image}:{version}')"

baas-smoke:
# Smoke-test the currently running BaaS gateway through the frontend verifier.
	cd $(FRONTEND_DIR) && node scripts/verify-connection.mjs

baas-release-smtp:
## Build and publish the SMTP-enabled BaaS wrapper image, then run SMTP smoke tests.
	docker build -f $(BAAS_DOCKERFILE) -t $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) -t $(BAAS_SMTP_IMAGE):latest $(BAAS_CONTEXT)
	docker push $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION)
	docker push $(BAAS_SMTP_IMAGE):latest
	cd $(FRONTEND_DIR) && npm run test:smtp && npm run test:email
	@echo "Published SMTP-enabled BaaS image $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) and latest."



## == Docker Environment Management ==

## These targets help fully clean and inspect our local Docker environment.
## SAFE DEFAULTS:
## - Volumes are preserved unless explicitly removed.
## - Database data stored in named volumes will survive normal cleanup.

docker-clean:
## Remove all unused containers, networks, images (dangling/unreferenced), and optionally, volumes.
	docker system prune -a --volumes=$(BOOL) -f

docker-rm-all:
## Remove all containers and images, prune system and builder cache.
	docker ps -aq | sort -u | xargs -r docker rm -f
	@docker images -aq | sort -u | while read -r image_id; do \
		if docker image inspect "$$image_id" >/dev/null 2>&1; then \
			docker rmi -f "$$image_id" || { \
				if docker image inspect "$$image_id" >/dev/null 2>&1; then exit 1; fi; \
			}; \
		fi; \
	done
	docker system prune -a --volumes=$(BOOL) -f
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f || true


docker_verify:
## Show all containers (running and stopped), images, volumes, networks, and disk usage.
	docker ps -a
	docker images -a
	docker volume ls
	docker network ls
	docker system df -v

docker_reclaim_cache:
## Remove BuildKit/buildx cache only.
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f || true

.PHONY: help all all-local pulls pushes bootstrap certs certs-trust certs-trust-system certs-trust-browser-host certs-doctor certs-trust-local env-format buildx-setup compose-build docker-prefetch-images vault-up vault-seed vault-publish vault-status vault-policy-sync vault-invite-token vault-fly-invite-token vault-fetch-shared vault-shared-doctor env-fetch-shared vault-publish-shared vault-status-shared vault-repair-shared vault-github-oidc vault-fly-create vault-fly-deploy vault-fly-publish vault-fly-github vault-fly vault-rotate-approles vault-verify-approles env-fetch env-backup env-restore-test db-password-check db-password-apply up app-images app-login app-images-push mail-up mail-logs mail-down calendar-up calendar-logs calendar-down healthcheck showcase playground playground-preview docs version baas-build baas-push baas-update baas-smoke baas-release-smtp docker-clean docker-clean-volumes docker-rm-all docker_verify docker_reclaim_cache