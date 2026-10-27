# Public mode: the frontends served to the internet through this host's Tailscale Funnel.
# docker-compose.public.yml rebuilds them keyless under the :public tag and hardens the gateway
# and bridge; scripts/public-funnel.sh opens the Funnel only after proving that, and closes it
# instantly. wiki/runbooks/public-funnel.md has the order of steps and what is NOT exposed.
#
# PUBLIC_COMPOSE_EXTRA: space-separated compose files layered between the link overlay and
# docker-compose.public.yml (the public file stays last so its :public tags and bundle args win).
PUBLIC_COMPOSE_EXTRA ?=
# Only the exact opt-in adds the local publish path; every other value preserves today's files.
# Its own variable, not += on PUBLIC_COMPOSE_EXTRA: a command-line PUBLIC_COMPOSE_EXTRA= would
# override the += and silently drop the overlay.
PUBLIC_PUBLISH_SOCKET_FILE = $(if $(filter 1,$(OSIONOS_PUBLISH_SOCKET)),docker-compose.publish-socket.yml)
PUBLIC_PORTS ?= 443
PUBLIC_SCRIPT = bash scripts/public-funnel.sh
PUBLIC_SERVICES = osionos-app opposite-osiris-web auth-gateway osionos-bridge local-https-proxy mail-web calendar-web
public-empty :=
public-space := $(public-empty) $(public-empty)
PUBLIC_COMPOSE_FILES = docker-compose.yml:docker-compose.grobase-link.yml$(subst $(public-space),,$(patsubst %,:%,$(PUBLIC_COMPOSE_EXTRA) $(PUBLIC_PUBLISH_SOCKET_FILE))):docker-compose.public.yml
# Recursive on purpose, like LINK_COMPOSE_ENV: the link's rootless values apply, and the
# later COMPOSE_FILE wins over the one LINK_COMPOSE_ENV sets.
PUBLIC_COMPOSE = $(WITH_GRAPH_RENDER_SHA) $(LINK_COMPOSE_ENV) COMPOSE_FILE='$(PUBLIC_COMPOSE_FILES)' \
	docker compose --env-file ./.env.local --env-file ./.env.public --profile dev

##@ Public (Funnel)
public-env: ## Create ./.env.public (git-ignored, mode 600) and mint its signing key
## Usage: make public-env
## Copies .env.public.example when absent, mints AUTH_LINK_SIGNING_KEY with openssl if empty
## (never printed) and names the decisions left to you: OSIONOS_ADMIN_EMAILS and
## AUTH_TRUSTED_PROXY_HOPS. Idempotent.
	@$(PUBLIC_SCRIPT) env

public-up: ## Rebuild as :public, recreate the frontends, then open the Funnel
## Usage: make public-up [PUBLIC_PORTS=443|all|apps] [PUBLIC_COMPOSE_EXTRA="file.yml …"] [OSIONOS_PUBLISH_SOCKET=1]
## RECREATES osionos-app, opposite-osiris-web, auth-gateway, osionos-bridge, local-https-proxy,
## mail-web and calendar-web
## with the public configuration (the :local images are kept), then runs `public-funnel.sh up`,
## which refuses to open the Funnel unless `verify --pre` passes. PUBLIC_PORTS=all adds 8443 and
## 10000 and needs a measured AUTH_TRUSTED_PROXY_HOPS; PUBLIC_PORTS=apps opens only the apps node.
	$(PUBLIC_COMPOSE) up -d --build --wait $(PUBLIC_SERVICES)
	$(PUBLIC_SCRIPT) up $(PUBLIC_PORTS)

public-down: ## Close the Funnel at once (the containers keep running on localhost)
## Usage: make public-down
## `tailscale funnel reset` on the main node and on the apps node when it answers; it prints which
## nodes were reset and exits 1 when one could not be (an apps node with state but a silent socket).
## The public containers are NOT stopped or rebuilt; they still serve 127.0.0.1.
	@$(PUBLIC_SCRIPT) down

public-status: ## Show the node name and which Funnel ports are open
## Usage: make public-status
	@$(PUBLIC_SCRIPT) status

public-verify: ## Check the public stack: PASS/FAIL/SKIP per fact, exit 1 on any FAIL
## Usage: make public-verify [PUBLIC_VERIFY_ARGS="--pre|443|all|apps"]
## --pre runs the checks that need no open Funnel; 443 or all also requires exactly that exposure.
	@$(PUBLIC_SCRIPT) verify $(PUBLIC_VERIFY_ARGS)
