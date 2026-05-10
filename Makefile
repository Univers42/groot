# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/10 15:04:54 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/10 22:28:50 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Makefile for managing mini-Baas infrastructure images and environment.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
VERSION ?=
BAAS_VERSION ?= $(if $(VERSION),$(if $(filter v%,$(VERSION)),$(VERSION),v$(VERSION)),v$(shell date +%F))
BAAS_DOCKERHUB_IMAGE ?= dlesieur/mini-baas-infra
BAAS_GHCR_IMAGE ?= ghcr.io/univers42/mini-baas-infra
BAAS_SMTP_IMAGE ?= dlesieur/mini-baas-infra
BAAS_SMTP_VERSION ?= smtp-v1
BAAS_SERVICES ?= kong gotrue postgrest postgres redis realtime
BAAS_DOCKERFILE := infrastructure/baas/Dockerfile
BAAS_CONTEXT := infrastructure/baas
FRONTEND_DIR := apps/opposite-osiris
BOOL ?= false
WEBSITE_URL := http://localhost:4322
OSIONOS_URL := http://localhost:3001
BRIDGE_URL := http://localhost:4000
AUTH_URL := http://localhost:8787/api/auth
BAAS_URL := http://localhost:8000
PLAYGROUND_VIEWER_URL := $(OSIONOS_URL)/playground-simulation/index.html
VSCODE_CLI ?= /usr/bin/code
CURL_HEALTH := curl --retry 30 --retry-delay 2 --retry-all-errors --retry-connrefused -fsS
VAULT_COMPOSE := docker compose --profile secrets
VAULT_ENV_CMD := $(VAULT_COMPOSE) run --rm vault-env node infrastructure/baas/scripts/vault-env.mjs
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
export HOST_UID HOST_GID
DOCKER_NODE := docker run --rm --user "$(HOST_UID):$(HOST_GID)" -e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" -v "$$PWD":/workspace -w /workspace node:22-alpine


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

all: bootstrap env-format vault-seed vault-verify-approles env-fetch up healthcheck showcase

bootstrap:
	$(DOCKER_NODE) node infrastructure/baas/scripts/bootstrap.mjs

env-format:
	$(DOCKER_NODE) node infrastructure/baas/scripts/vault-env.mjs format

vault-up:
	$(VAULT_COMPOSE) up -d --build vault
	$(VAULT_COMPOSE) run --rm --build vault-init

vault-seed: vault-up
	$(VAULT_ENV_CMD) seed

vault-verify-approles: vault-seed
	$(VAULT_ENV_CMD) verify-approles

env-fetch: vault-up
	$(VAULT_ENV_CMD) fetch

env-backup:
	$(DOCKER_NODE) node infrastructure/baas/scripts/vault-env.mjs backup

env-restore-test: vault-seed
	$(VAULT_ENV_CMD) roundtrip

up:
	docker compose up -d --build

mail-up:
## Start osionos Mail and the Gmail bridge with Docker Compose.
	docker compose up -d --build mail mail-bridge

mail-logs:
## Follow osionos Mail and Gmail bridge logs.
	docker compose logs -f mail mail-bridge

mail-down:
## Stop osionos Mail and the Gmail bridge containers.
	docker compose stop mail mail-bridge

healthcheck:
	docker compose ps
	$(CURL_HEALTH) $(BRIDGE_URL)/api/auth/bridge/health
	$(CURL_HEALTH) $(OSIONOS_URL) >/dev/null
	$(CURL_HEALTH) $(WEBSITE_URL) >/dev/null
	$(CURL_HEALTH) -o /dev/null -w 'auth-gateway-http-%{http_code}\n' $(AUTH_URL)/availability
	docker compose exec -T -e BAAS_INTERNAL_URL=http://kong:8000 opposite-osiris node scripts/container-only.mjs node scripts/verify-connection.mjs

showcase:
	@printf '\nPipeline ready. Open these local services:\n'
	@printf '  Website:             %s\n' '$(WEBSITE_URL)'
	@printf '  osionos app:         %s\n' '$(OSIONOS_URL)'
	@printf '  osionos bridge API:  %s\n' '$(BRIDGE_URL)'
	@printf '  Auth gateway:        %s\n' '$(AUTH_URL)'
	@printf '  BaaS gateway:        %s\n\n' '$(BAAS_URL)'

playground: healthcheck playground-preview
	docker compose run --rm --build playground-simulation
	$(MAKE) showcase

playground-preview:
	@printf '\nSimulation preview: Docker Playwright will create a throwaway account and bridge it into osionos.\n'
	@printf 'Opening the VS Code simulation viewer: %s\n' '$(PLAYGROUND_VIEWER_URL)'
	@if [ -x '$(VSCODE_CLI)' ]; then \
		'$(VSCODE_CLI)' --reuse-window '$(PLAYGROUND_VIEWER_URL)' >/dev/null 2>&1 || printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	else \
		printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	fi

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
	docker ps -aq | xargs -r docker rm -f
	docker images -aq | xargs -r docker rmi -f
	docker system prune -a --volumes=$(BOOL) -f
	docker builder prune -a -f


docker_verify:
## Show all containers (running and stopped), images, volumes, networks, and disk usage.
	docker ps -a
	docker images -a
	docker volume ls
	docker network ls
	docker system df -v

docker_reclaim_cache:
## Remove BuildKit/buildx cache only.
	docker builder prune -a -f

.PHONY: help all bootstrap env-format vault-up vault-seed vault-verify-approles env-fetch env-backup env-restore-test up mail-up mail-logs mail-down healthcheck showcase playground playground-preview version baas-build baas-push baas-update baas-smoke baas-release-smtp docker-clean docker-clean-volumes docker_rm_all docker_verify docker_reclaim_cache