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
