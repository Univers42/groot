# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    compose.mk                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:58:05 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:58:06 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Docker Compose lifecycle targets.
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

up-infra: certs docker-prefetch-images compose-build
## Build and start backend infrastructure only; skips hot-reload frontends (no dev profile).
	@COMPOSE_PROFILES= docker compose kill local-https-proxy db-bootstrap project-db-init gotrue kong postgrest pg-meta supavisor osionos-bridge >/dev/null 2>&1 || true
	@COMPOSE_PROFILES= docker compose rm -f local-https-proxy db-bootstrap project-db-init gotrue kong postgrest pg-meta supavisor osionos-bridge >/dev/null 2>&1 || true
	COMPOSE_PROFILES= docker compose up -d --no-build --pull never --wait postgres
	$(MAKE) db-password-apply
	COMPOSE_PROFILES= docker compose up -d --no-build --pull never
	$(MAKE) compose-wait COMPOSE_HEALTHY_SERVICES='$(COMPOSE_HEALTHY_SERVICES_INFRA)' COMPOSE_RUNNING_SERVICES='$(COMPOSE_RUNNING_SERVICES_INFRA)' COMPOSE_COMPLETED_SERVICES='$(COMPOSE_COMPLETED_SERVICES_INFRA)'