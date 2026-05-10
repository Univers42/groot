# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/10 15:04:54 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/10 16:01:30 by dlesieur         ###   ########.fr        #
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

.DEFAULT_GOAL := all

all: bootstrap up healthcheck showcase

bootstrap:
	docker run --rm -v "$$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/bootstrap.mjs

up:
	docker compose up -d --build

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


# =============================================================
# Docker Environment Management
# =============================================================

# These targets help fully clean and inspect our local Docker environment.
# SAFE DEFAULTS:
# - Volumes are preserved unless explicitly removed.
# - Database data stored in named volumes will survive normal cleanup.

docker-clean:
# that will remove all unused containers, networks, images (both dangling and unreferenced), and optionally, volumes.
	docker system prune -a --volumes=$(BOOL) -f

docker-rm-all:
	docker ps -aq | xargs -r docker rm -f
	docker images -aq | xargs -r docker rmi -f
	docker system prune -a --volumes=$(BOOL) -f
	docker builder prune -a -f


docker_verify:
# show all containers(running and stopped), images, volumes, networks, and disk usage
	docker ps -a
	docker images -a
	docker volume ls
	docker network ls
	docker system df -v

docker_reclaim_cache:
# Remove BuildKit/buildx cache only
	docker builder prune -a -f

.PHONY: all bootstrap up healthcheck showcase playground playground-preview version baas-build baas-push baas-update baas-smoke baas-release-smtp docker-clean docker-clean-volumes docker_rm_all docker_verify docker_reclaim_cache