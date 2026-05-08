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

.PHONY: version baas-build baas-push baas-update baas-smoke baas-release-smtp

## Publish a versioned BaaS release to DockerHub and GHCR, then smoke-test it.
version: baas-update baas-build baas-push baas-smoke
	@echo "Published mini-baas-infra $(BAAS_VERSION) to DockerHub and GHCR."

## Tag the locally built composable mini-baas images with versioned and latest tags.
baas-build:
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

## Push both DockerHub and GHCR version/latest aliases for every BaaS service image.
baas-push:
	@for service in $(BAAS_SERVICES); do \
		docker push "$(BAAS_DOCKERHUB_IMAGE)-$$service:$(BAAS_VERSION)"; \
		docker push "$(BAAS_DOCKERHUB_IMAGE)-$$service:latest"; \
		docker push "$(BAAS_GHCR_IMAGE)/$$service:$(BAAS_VERSION)"; \
		docker push "$(BAAS_GHCR_IMAGE)/$$service:latest"; \
	done

## Pin the wrapper Dockerfile to the versioned image tag, never latest.
baas-update:
	python3 -c "from pathlib import Path; path=Path('$(BAAS_DOCKERFILE)'); version='$(BAAS_VERSION)'; image='$(BAAS_DOCKERHUB_IMAGE)-kong'; lines=path.read_text().splitlines(); idx=next((i for i,line in enumerate(lines) if line.startswith('FROM ')), None); assert idx is not None, f'No FROM line found in {path}'; lines[idx]=f'FROM {image}:{version}'; path.write_text('\\n'.join(lines) + '\\n'); print(f'Pinned {path} to {image}:{version}')"

## Smoke-test the currently running BaaS gateway through the frontend verifier.
baas-smoke:
	cd $(FRONTEND_DIR) && node scripts/verify-connection.mjs

## Build and publish the SMTP-enabled BaaS wrapper image, then run SMTP smoke tests.
baas-release-smtp:
	docker build -f $(BAAS_DOCKERFILE) -t $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) -t $(BAAS_SMTP_IMAGE):latest $(BAAS_CONTEXT)
	docker push $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION)
	docker push $(BAAS_SMTP_IMAGE):latest
	cd $(FRONTEND_DIR) && npm run test:smtp && npm run test:email
	@echo "Published SMTP-enabled BaaS image $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) and latest."
