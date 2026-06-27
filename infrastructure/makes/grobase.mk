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
## on /, /pricing, /security) + pa11y + CSP check + html-validate. Fails on any gate.
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
## Ensure the standalone apps/grobase backend is up. If it's down but the grobase secrets are already present (this machine was bootstrapped before), auto-start it (`make -C apps/grobase up`). If the secrets are ABSENT (truly fresh machine), stop with bootstrap instructions — `make all` cannot unseal vault42 non-interactively.
	@if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q '^mini-baas_mini-baas$$' \
		&& docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mini-baas-kong$$'; then \
		exit 0; \
	fi; \
	if [ -f apps/grobase/.env ]; then \
		echo '[backend] grobase backend down but its secrets are present → starting it (make -C apps/grobase up)…' >&2; \
		$(MAKE) -C apps/grobase up; \
	else \
		echo '[backend] grobase backend not running — and its secrets are missing (apps/grobase/.env absent).' >&2; \
		echo '          This looks like a FRESH machine. `make all` cannot unseal vault42 for you; run bootstrap:' >&2; \
		echo '' >&2; \
		echo '            1) copy  ~/.config/42ctl/keystore.v42  from your old machine to the same path here' >&2; \
		echo '               (it is the vault42 master key — the one secret in neither git nor the vault)' >&2; \
		echo '            2) make bootstrap   (submodules → secrets ← vault42 → backend → restore data → frontends)' >&2; \
		echo '' >&2; \
		echo '          backend only (if secrets are already in place):  make -C apps/grobase up' >&2; \
		exit 1; \
	fi

restore-if-empty:
## FAIL-SAFE auto-restore (wired into `make all`): loads the all-engine snapshot ONLY when EVERY running primary engine (postgres osionos, mysql ops, mongo activity) is CONFIRMED empty. Any engine with data, or any uncertainty (unreachable / query error), → SKIP (never wipes). Logic in scripts/restore-if-empty.sh.
	@sh scripts/restore-if-empty.sh

frontends-up: certs docker-prefetch-images compose-build
## Build and start ONLY the root frontends against the running grobase backend.
	docker compose --env-file ./.env.local up -d --build --wait $(ROOT_FRONTENDS)
	$(MAKE) compose-wait
