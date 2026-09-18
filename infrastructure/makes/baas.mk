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
## the grobase control plane), then rebuild osionos-app with the BaaS env baked
## in and restart it. Needs the grobase stack up (make -C apps/grobase up).
	@$(MAKE) -C apps/grobase seed-live-demo APP_ENV_FILE=$(CURDIR)/apps/osionos/app/.env
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

live-data-ensure:
## Converge the osionos LIVE-DATABASE credential: issue the tenant API key when
## ./.env.local has none (its cleartext is returned ONCE at issue time and is
## unrecoverable, so a lost .env.local can only be repaired by issuing a new one)
## and re-stamp the seeded demo rows onto the new owner principal in the same
## step — a new key has a new uuid, and owner-scoped reads would otherwise return
## ZERO rows: authenticated, silent, empty. Idempotent: a converged stack no-ops.
	@bash scripts/ensure-live-data-access.sh

live-data-check:
## Report whether the live-database credential is converged; non-zero if a repair
## is needed. Changes nothing — safe for CI and healthcheck.
	@bash scripts/ensure-live-data-access.sh --check

mounts-reencrypt:
## Repair live mounts whose stored DSN ciphertext no longer opens under the
## CURRENT VAULT_ENC_KEY (every /connect 500s). On a machine with no vault42
## keystore, grobase SELF-GENERATES its secrets, so regenerating them while the
## database survives orphans every ciphertext. Re-encrypts via the registry
## itself, preserving mount ids so no reference breaks. Idempotent.
	@bash scripts/reencrypt-mounts.sh

mounts-check:
## Report which live mounts fail to decrypt; non-zero if any do. Changes nothing.
	@bash scripts/reencrypt-mounts.sh --check

.PHONY: seed-live-demo osionos-app-live live-data-ensure live-data-check \
        mounts-reencrypt mounts-check
