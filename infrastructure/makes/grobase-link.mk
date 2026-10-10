# grobase anywhere: the root frontends run on this daemon, grobase runs here (local), on an
# ssh-reachable machine (the born2root VM, a LAN box, a VPS) or behind a Kong URL.
# scripts/grobase-link.sh resolves GROBASE_TARGET and opens the path; the grobase-link
# relay in docker-compose.grobase-link.yml gives the frontends the grobase names.
# `make backend-up` refuses while the relay runs: the two must not share the names.
#
# The kind of connection is configuration: this machine's ./.env.grobase-link (git-ignored;
# .env.grobase-link.example documents it) holds its GROBASE_TARGET, and `make link
# GROBASE_TARGET=…` or the environment wins over it for one run. Empty here means "not given",
# which the script reads as "use the file, else auto". The script resolves the settings
# (`conf`), so make asks it for the one it needs rather than parsing the file a second time.
GROBASE_TARGET ?=
GROBASE_LINK_DIR ?= $(or $(XDG_RUNTIME_DIR),/tmp)/track-binocle-link
GROBASE_LINK_HOST_PORT ?= $(shell bash scripts/grobase-link.sh conf GROBASE_LINK_HOST_PORT)
# 443 needs a privileged bind, which rootless Docker cannot do (ip_unprivileged_port_start).
LINK_VHOST_HTTPS_PORT ?= $(shell if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless \
	&& [ "$$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)" -gt 443 ]; then echo 9443; else echo 443; fi)
LINK_SCRIPT = GROBASE_TARGET='$(GROBASE_TARGET)' GROBASE_LINK_DIR='$(GROBASE_LINK_DIR)' \
	GROBASE_LINK_HOST_PORT='$(GROBASE_LINK_HOST_PORT)' LOCAL_CA_CERT='$(LOCAL_CA_CERT)' bash scripts/grobase-link.sh
# After every link: one request per grobase name from inside each frontend on grobase's
# network, then the browser's path through the TLS edge and the browser stores' trust in
# the edge's CA (scripts/lib/grobase-link-verify.sh). In `link` itself the trust line is a
# note (LINK_VERIFY_TRUST=note): the import that fixes a store comes later, in
# link-frontends-up, whose own final verify fails on it like `make link-verify` does.
LINK_VERIFY = $(LINK_SCRIPT) verify
# Recursive on purpose: the shell calls behind LINK_VHOST_HTTPS_PORT and GROBASE_LINK_HOST_PORT
# run only when a link-* target uses them, not on every `make`.
# MINI_BAAS_WAF_TLS_GID=none: grobase's WAF, the one reader of the TLS key that needs gid 101,
# runs where grobase runs, not here; the local key stays 0600 for local-https-proxy alone.
LINK_COMPOSE_ENV = GROBASE_LINK_DIR='$(GROBASE_LINK_DIR)' COMPOSE_FILE='docker-compose.yml:docker-compose.grobase-link.yml' \
	TRACK_BINOCLE_VHOST_HTTPS_PORT='$(LINK_VHOST_HTTPS_PORT)' MINI_BAAS_WAF_TLS_GID=none
LINK_COMPOSE = $(LINK_COMPOSE_ENV) docker compose --env-file ./.env.local

link:
## Reach grobase wherever it runs: open the path, derive ./.env.local from that grobase's secrets, start the relay (or stop it in local mode), then verify it from inside every frontend already running. The target and its kind come from GROBASE_TARGET=auto|local|ssh://…|<alias>|http(s)://… on this line, else from ./.env.grobase-link.
	@$(LINK_SCRIPT) up
	@if [ "$$($(LINK_SCRIPT) mode)" = local ]; then \
		docker ps -q --filter label=com.docker.compose.service=grobase-link | grep -q . && $(LINK_COMPOSE) rm -sf grobase-link; \
		echo '[link] local mode: nothing to relay; the monolithic pipeline (make all / backend-up) applies.' >&2; \
	else \
		$(LINK_SCRIPT) env; \
		docker network inspect mini-baas_mini-baas >/dev/null 2>&1 || docker network create mini-baas_mini-baas >/dev/null; \
		$(LINK_COMPOSE) up -d --force-recreate --wait grobase-link; \
	fi
	@LINK_VERIFY_TRUST=note $(LINK_VERIFY)

link-status:
## Is the link open, and does Kong answer through it.
	@$(LINK_SCRIPT) status

link-verify:
## Prove the link from where it matters: one request per grobase name (Kong, Redis, Mailpit smtp+http, realtime) from inside every frontend on grobase's network, then the browser's path through the TLS edge; exit 1 on any FAIL.
	@$(LINK_VERIFY)

link-down:
## Close the link: stop the relay, the ssh master and its forwards. The frontends lose the backend until `make link` or `make backend-up`.
	@$(LINK_COMPOSE) rm -sf grobase-link >/dev/null 2>&1 || true
	@$(LINK_SCRIPT) down

# What `make all` does with models-migrate, driven over the link: groot's models/*.sql land
# in the postgres of the grobase the frontends talk to (2026-10-09: 7 osionos tables were
# missing in the VM's grobase because nothing had ever run it there). Idempotent; slow over
# ssh (one docker exec per file through docker's ssh transport, ~2 min).
link-models-migrate:
## Apply groot's models/*.sql to the LINKED grobase's postgres (local = this daemon, ssh = the target's daemon through docker's ssh transport; direct mode has no database and refuses). Idempotent, part of link-frontends-up.
	@host="$$($(LINK_SCRIPT) docker-host)"; \
	if [ -n "$$host" ]; then DOCKER_HOST="$$host" $(MAKE) --no-print-directory models-migrate; else $(MAKE) --no-print-directory models-migrate; fi

link-frontends-up: link link-models-migrate
## Build and start the root frontends here against the linked grobase (after link-models-migrate; frontends-up, in a non-local mode with the relay overlay and the vhost on LINK_VHOST_HTTPS_PORT), trust the local CA in this user's browser stores (no sudo; certs-trust-user), then verify the link and that trust from inside every frontend.
	@if [ "$$($(LINK_SCRIPT) mode)" = local ]; then \
		$(MAKE) --no-print-directory frontends-up certs-trust-user; \
	else \
		$(LINK_COMPOSE_ENV) $(MAKE) --no-print-directory frontends-up certs-trust-user; \
	fi
	@$(LINK_VERIFY)

link-healthcheck:
## link-verify, then the stack healthcheck with the backend probed through the link's loopback Kong port.
	@$(LINK_VERIFY)
	@if [ "$$($(LINK_SCRIPT) mode)" = local ]; then \
		$(MAKE) --no-print-directory healthcheck; \
	else \
		$(LINK_COMPOSE_ENV) $(MAKE) --no-print-directory healthcheck BAAS_URL='http://127.0.0.1:$(GROBASE_LINK_HOST_PORT)'; \
	fi

# E2E_SPECS narrows the run (E2E_SPECS=specs/t43-landing-sign-in.spec.ts); empty = the suite.
E2E_SPECS ?=
link-e2e: link-healthcheck
## link-healthcheck, then the Playwright smoke (tests/e2e) in its pinned container against the frontends served here through the linked grobase; the stack must already be up (link-frontends-up).
	@bash tests/e2e/run.sh $(E2E_SPECS)
