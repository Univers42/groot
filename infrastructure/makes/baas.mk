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

OSIONOS_APP_ENV := apps/osionos/app/.env

seed-live-demo:
## Seed the live-database demo (pg-commerce + mysql-ops + mongo-activity through
## the mini-baas control plane), then rebuild osionos-app with the BaaS env
## baked in and restart it. Needs the mini-baas stack up (make -C apps/baas/mini-baas-infra up).
	@$(MAKE) -C apps/baas/mini-baas-infra seed-live-demo
	@$(MAKE) osionos-app-live

osionos-app-live:
## Rebuild + restart osionos-app with the VITE_BAAS_* values from the app .env
## (vite inlines env at build time; the seeder writes the live-demo keys there).
## Two --env-file flags: the root .env keeps its port interpolations, the app
## .env supplies the VITE_BAAS_* build args (later files win).
	@test -f $(OSIONOS_APP_ENV) || { echo "missing $(OSIONOS_APP_ENV) — run make seed-live-demo first"; exit 1; }
	@touch .env
	docker compose --env-file .env --env-file $(OSIONOS_APP_ENV) build osionos-app
	docker compose --env-file .env --env-file $(OSIONOS_APP_ENV) up -d osionos-app

.PHONY: seed-live-demo osionos-app-live
