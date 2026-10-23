##@ Docker
app-images: ## Build the local images for the apps, bridges and playground
## Build the local Docker images for the website, osionos, Mail, Calendar, bridges, and BaaS
## gateway.
	$(MAKE) compose-build BAKE_GROUP=testing BAKE_TARGETS='$(BAKE_TARGETS) playground-simulation'

##@ Pipeline
healthcheck: certs ## Probe the backend, website, osionos app, bridge and auth gateway
## Verify the grobase backend, website, osionos app, bridge, and auth gateway.
	docker compose ps
	@echo '$(CURL_HEALTH) -H "apikey: <SB_KONG_KEY>" $(BAAS_URL)/auth/v1/health'
	@$(CURL_HEALTH) -H "apikey: $(BAAS_HEALTH_KEY)" $(BAAS_URL)/auth/v1/health >/dev/null
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
# The gateway's probe moved from /availability to /health (docker-compose.yml, auth-gateway).
# No --retry-all-errors on the route pick: a 404 there is the answer, not a failure to retry.
# Caveat: a gateway still refusing connections after ~60 s is probed on /health; an old one then
# fails on the 404 instead of falling back.
	@route=health; \
	[ "$$(curl --cacert $(LOCAL_CA_CERT) --retry 30 --retry-delay 2 --retry-connrefused -m 5 -s -o /dev/null -w '%{http_code}' $(AUTH_URL)/health || true)" != 404 ] || route=availability; \
	$(CURL_HEALTH) -o /dev/null -w 'auth-gateway-https-%{http_code}\n' $(AUTH_URL)/$$route
# drawnosaurus is part of the default stack now (T12-P1b), so it is probed like any other
# frontend. Two assertions, because the interesting failure is not "port closed": if the
# gateway is down, nginx answers 503 from its own fallback page and a plain reachability
# check would pass. So the board LIST must come back 200 — that is the surface the
# Whiteboard tab actually embeds.
	$(CURL_HEALTH) $(DRAWNOSAURUS_URL)/healthz >/dev/null
	@boards_status="$$($(CURL_HEALTH) -o /dev/null -w '%{http_code}' $(DRAWNOSAURUS_URL)/v1/boards || true)"; \
	if [ "$$boards_status" = "200" ]; then \
		echo '[healthcheck] drawnosaurus board list reachable'; \
	else \
		echo "[healthcheck] expected drawnosaurus /v1/boards to return 200, got HTTP $$boards_status" >&2; \
		exit 1; \
	fi

showcase: ## Print every local URL the running stack exposes (last step of make all)
## Recap every local URL the RUNNING stack exposes — click to open. Last step of `make all`. (Only
## services that are actually up are listed.) Logic in scripts/showcase.sh.
	@sh scripts/showcase.sh

check_health_apps: ## Probe each app on localhost and in production: UP/DOWN per environment
## App health matrix — each app probed on localhost AND in production (Vercel sites + fly backend):
## UP/DOWN per environment with clickable URLs. Logic in scripts/check-health-apps.sh.
	@sh scripts/check-health-apps.sh
