# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    common.mk                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:58:03 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:58:04 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Common variables and shared Makefile utilities.
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
COMPOSE_PROFILES ?= dev
export COMPOSE_PROFILES COMPOSE_PROGRESS BUILDKIT_PROGRESS BUILDX_BUILDER DOCKER_BUILDKIT COMPOSE_DOCKER_CLI_BUILD COMPOSE_BAKE REGISTRY_CACHE_PREFIX TRACK_BINOCLE_BIND_ADDR
DOCKER_PULL_ATTEMPTS ?= 1
DOCKER_PULL_TIMEOUT ?= 120
DOCKER_PULL_KILL_AFTER ?= 15
DOCKER_PREFETCH_JOBS ?= 8
DOCKER_PREFETCH_SCOPE ?= all
COMPOSE_WAIT_TIMEOUT ?= 300
COMPOSE_WAIT_INTERVAL ?= 2
COMPOSE_HEALTHY_SERVICES_INFRA ?= postgres local-https-proxy pg-meta gotrue kong osionos-bridge
COMPOSE_HEALTHY_SERVICES ?= $(COMPOSE_HEALTHY_SERVICES_INFRA) auth-gateway mail-bridge mail osionos-app opposite-osiris calendar-bridge calendar
# supavisor restarts intermittently in CI, but the stack does not depend on it for readiness.
COMPOSE_RUNNING_SERVICES_INFRA ?= redis postgrest
COMPOSE_RUNNING_SERVICES ?= $(COMPOSE_RUNNING_SERVICES_INFRA) mailpit
COMPOSE_COMPLETED_SERVICES_INFRA ?= db-bootstrap project-db-init local-runtime-secrets
COMPOSE_COMPLETED_SERVICES ?= $(COMPOSE_COMPLETED_SERVICES_INFRA) opposite-osiris-deps
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
VAULT_READER_TOKEN_TTL ?= 24h
VAULT_WRITER_TOKEN_TTL ?= 8h
VAULT_TEAM_TOKEN_FILE ?= .vault/track-binocle-$(VAULT_TEAM_ROLE).env
VAULT_READER_TOKEN_FILE ?= .vault/track-binocle-reader.env
VAULT_WRITER_TOKEN_FILE ?= .vault/track-binocle-writer.env
VAULT_ADMIN_TOKEN_FILE ?= .vault/track-binocle-admin.env
VAULT_SESSION_FILE ?= .vault/track-binocle-session.env
VAULT_CLI_TOKEN_FILE ?= $(HOME)/.vault-token
VAULT_SESSION_ADDR ?= $(if $(VAULT_ADDR),$(VAULT_ADDR),$(FLY_VAULT_URL))
VAULT_NAMESPACE ?=
VAULT_USER_AUTH_METHOD ?= github
VAULT_APPROLE_AUTH_PATH ?= approle
VAULT_ROLE_ID_FILE ?= .vault/track-binocle-role-id
VAULT_SECRET_ID_FILE ?= .vault/track-binocle-secret-id
VAULT_JWT_AUTH_PATH ?= $(VAULT_GITHUB_OIDC_AUTH_PATH)
VAULT_JWT_ROLE ?= $(VAULT_GITHUB_OIDC_ROLE)
VAULT_ADMIN_TOKEN_TTL ?= 2h
VAULT_SECRET_PATH ?=
VAULT_SECRET_OUTPUT ?= .vault/track-binocle-secret.json
VAULT_TOKEN_FILE ?= $(VAULT_READER_TOKEN_FILE)
VAULT_PUBLISH_TOKEN_FILE ?= $(VAULT_WRITER_TOKEN_FILE)
ADMIN_CRED_LOST_RECEIPT_FILE ?= .vault/admin-cred-lost-receipt.env
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
FLY_BIN := $(shell command -v flyctl 2>/dev/null || command -v fly 2>/dev/null)
VAULT_FLY_IMAGE ?= flyio/flyctl:latest
FLY_DOCKER := docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly
FLY ?= $(if $(FLY_BIN),$(FLY_BIN),$(FLY_DOCKER))
VAULT_FLY_RESET_PHRASE := destroy-$(FLY_VAULT_APP)
VAULT_FLY_RESET_CONFIRM ?=
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
export HOST_UID HOST_GID
NODE_BIN ?= $(shell command -v node 2>/dev/null || true)
DOCKER_NODE := docker run --rm --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -v "$$PWD":/workspace -w /workspace node:22-alpine
DOCKER_NODE_SHARED := docker run --rm --network host --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -e VAULT_ADDR -e VAULT_NAMESPACE -e VAULT_TOKEN -e VAULT_ENV_PREFIX -e NODE_EXTRA_CA_CERTS=/workspace/apps/baas/certs/track-binocle-local-ca.pem -v "$$PWD":/workspace -w /workspace node:22-alpine
DOCKER_NODE_VAULT := docker run --rm --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -e VAULT_ADDR -e VAULT_NAMESPACE -e VAULT_TOKEN -e VAULT_ENV_PREFIX -e VAULT_TEAM_ROLE -e VAULT_TOKEN_TTL -e VAULT_TEAM_TOKEN_FILE -e VAULT_PUBLIC_ADDR -e VAULT_GITHUB_OIDC_AUTH_PATH -e VAULT_GITHUB_OIDC_ROLE -e VAULT_GITHUB_OIDC_REPOSITORY -e VAULT_GITHUB_OIDC_AUDIENCE -e VAULT_GITHUB_AUTH_PATH -e VAULT_GITHUB_ORG -e VAULT_GITHUB_TEAM -v "$$PWD":/workspace -w /workspace node:22-alpine
NODE_RUN := $(if $(NODE_BIN),$(NODE_BIN),$(DOCKER_NODE) node)
NODE_RUN_SHARED := $(if $(NODE_BIN),$(NODE_BIN),$(DOCKER_NODE_SHARED) node)

help:
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;39m        Track Binocle: Makefile Pipeline & Utilities         \033[0m"
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@printf "\033[1;38;5;45mUsage:\033[0m make [target]\n\n"
	@awk 'BEGIN { section = "" } /^[a-zA-Z0-9][^: ]*:/ { target=$$1; sub(":.*", "", target); getline; if ($$0 ~ /^## /) { desc = substr($$0, 4); if (desc ~ /^== /) { section = substr(desc, 4); printf("\n\033[1;38;5;220m%s\033[0m\n", section); } else { printf("  \033[1;38;5;81m%-22s\033[0m %s\n", target, desc); } } }' $(MAKEFILE_LIST)
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;245mFor docs: make docs or see README.md\033[0m"

.PHONY: help all all-local pulls pushes bootstrap certs certs-trust certs-trust-system certs-trust-browser-host certs-doctor certs-trust-local env-format buildx-setup compose-build docker-prefetch-images vault-up vault-seed vault-publish vault-status vault-policy-sync vault-invite-token vault-fly-invite-token vault-reader-token vault-writer-token vault-fetch-shared vault-shared-doctor vault-session-node-check vault-session-check vault-login-user vault-login-approle vault-login-jwt vault-login-fly-admin vault-session-status vault-get-secrets vault-kv-export vault-session-reader-token vault-session-writer-token vault-logout check-env login-user login-approle login-jwt get-secrets logout env-fetch-shared vault-publish-shared vault-status-shared vault-repair-shared vault-github-oidc vault-fly-create vault-fly-deploy vault-fly-publish vault-fly-github vault-fly admin-cred-lost vault-fly-reset vault-rotate-approles vault-verify-approles env-fetch env-backup env-restore-test db-password-check db-password-apply compose-wait up up-infra app-images app-login app-images-push mail-up mail-logs mail-down calendar-up calendar-logs calendar-down healthcheck showcase playground playground-preview docs version baas-build baas-push baas-update baas-smoke baas-release-smtp docker-clean docker-clean-volumes docker-rm-all docker_verify docker_reclaim_cache