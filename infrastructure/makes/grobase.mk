grobase-up: docker-prefetch-images
## Start the Grobase marketing site dev server (http://127.0.0.1:4324).
	$(MAKE) compose-build BAKE_GROUP=grobase BAKE_TARGETS='grobase-site'
	docker compose --profile grobase up -d --no-build --pull never grobase-site

grobase-logs:
## Follow Grobase marketing site logs.
	docker compose --profile grobase logs -f grobase-site

grobase-down:
## Stop the Grobase marketing site containers.
	docker compose --profile grobase stop grobase-site

grobase-audit:
## Run the full Grobase quality gate: prod build + preview + Lighthouse (>=90 x4
## on /, /pricing, /compare) + pa11y + CSP check + html-validate. Fails on any gate.
	docker compose --profile grobase build grobase-site-audit
	docker compose --profile grobase run --rm grobase-site-audit

grobase-e2e:
## Run the Playwright end-to-end suite (story spine, scroll morph, one-shot Big
## Bang, latch, reduced-motion + no-JS dignity, CSP/console cleanliness, keyboard
## explorer) against a prod preview, using the audit image's system Chromium.
	docker compose --profile grobase build grobase-site-audit
	docker compose --profile grobase run --rm grobase-site-audit npm run test:e2e

# --- Grobase backend integration (standalone apps/grobase stack = docker project mini-baas) ---
.PHONY: backend-up frontends-up

# Frontends the root pipeline owns. The backend (postgres/gotrue/kong/postgrest/...)
# is the running apps/grobase stack and must NOT be re-upped from here.
ROOT_FRONTENDS := osionos-bridge osionos-app auth-gateway opposite-osiris-web local-https-proxy livekit

backend-up:
## Guard only: verify the standalone apps/grobase backend is already running (never re-ups it).
	@if ! docker network ls --format '{{.Name}}' 2>/dev/null | grep -q '^mini-baas_mini-baas$$' \
		|| ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mini-baas-kong$$'; then \
		echo '[backend] grobase backend not running — start it from apps/grobase (make -C apps/grobase up)' >&2; \
		exit 1; \
	fi

frontends-up: certs docker-prefetch-images compose-build
## Build and start ONLY the root frontends against the running grobase backend.
	docker compose --env-file ./.env.local up -d --build --wait $(ROOT_FRONTENDS)
	$(MAKE) compose-wait
