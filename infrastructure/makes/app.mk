app-images:
## Build the local Docker images for the website, osionos, Mail, Calendar, bridges, and BaaS gateway.
	$(MAKE) compose-build BAKE_GROUP=testing BAKE_TARGETS='$(BAKE_TARGETS) playground-simulation'

app-login:
## Log in to DockerHub using DOCKER_USER/DOCKER_PAT from the shell or ignored env files.
	@set +u; set -a; \
	for env_file in .env.local .env; do \
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
	for env_file in .env.local .env; do \
		if [[ -f "$$env_file" ]]; then . "$$env_file"; fi; \
	done; \
	set +a; set -u; \
	docker_user="$${DOCKER_USER:-$${DOCKER_LOGIN:-}}"; \
	if [[ -z "$$docker_user" ]]; then \
		echo 'DOCKER_USER must be set in the shell or an ignored env file.'; \
		exit 1; \
	fi; \
	for spec in \
		'track-binocle-postgres:local track-binocle-postgres' \
		'track-binocle/mini-baas-kong:local track-binocle-mini-baas-kong' \
		'track-binocle/osionos-app:local track-binocle-osionos-app' \
		'track-binocle/mail-bridge:local track-binocle-mail-bridge' \
		'track-binocle/mail:local track-binocle-mail' \
		'track-binocle/calendar-bridge:local track-binocle-calendar-bridge' \
		'track-binocle/calendar:local track-binocle-calendar' \
		'track-binocle/auth-gateway:local track-binocle-auth-gateway' \
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

healthcheck: certs
## Verify the grobase backend, website, osionos app, bridge, and auth gateway.
	docker compose ps
	$(CURL_HEALTH) -H "apikey: $(BAAS_HEALTH_KEY)" $(BAAS_URL)/auth/v1/health >/dev/null
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

showcase:
## Recap every local URL the RUNNING stack exposes — click to open. Last step of `make all`. (Only services that are actually up are listed.) Logic in scripts/showcase.sh.
	@sh scripts/showcase.sh

check_health_apps:
## App health matrix — each app probed on localhost AND in production (Vercel sites + fly backend): UP/DOWN per environment with clickable URLs. Logic in scripts/check-health-apps.sh.
	@sh scripts/check-health-apps.sh
