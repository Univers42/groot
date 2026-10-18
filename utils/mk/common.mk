# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    common.mk                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:58:03 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:58:04 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Common variables and shared Makefile utilities.
COMPOSE_PROGRESS ?= plain
BUILDKIT_PROGRESS ?= plain
BUILDX_BUILDER ?= default
BUILDX_IMAGE ?= moby/buildkit:buildx-stable-1
BUILDX_BOOTSTRAP_TIMEOUT ?= 120
BUILDX_BOOTSTRAP_KILL_AFTER ?= 15
DOCKER_BUILDKIT ?= 1
COMPOSE_DOCKER_CLI_BUILD ?= 1
COMPOSE_BAKE ?= 1
REGISTRY_CACHE_PREFIX ?=
BAKE_FILE ?= docker-bake.hcl
BAKE_GROUP ?= default
BAKE_TARGETS ?= osionos-app mail calendar opposite-osiris-node
# Best-effort Make-level default for consumers that just read this variable.
# GNU Make 4.4.1's $(shell)+export machinery has proven flaky here even with
# one-time (:=) expansion and its own export line (reproduced: identical
# expression, 1-in-3 runs wrong) — the `all`/`frontends-up` recipes that actually launch
# Docker do NOT rely on this value; they call detect-bind-addr.sh directly at
# shell-execution time instead, which sidesteps the flake entirely.
ifeq ($(origin TRACK_BINOCLE_BIND_ADDR),undefined)
TRACK_BINOCLE_BIND_ADDR := $(shell sh infrastructure/scripts/detect-bind-addr.sh)
endif
# Exported on its own line, not bundled with the list below: grouping it into a
# shared `export A B C ...` list re-triggers the same GNU Make 4.4.1 recursion
# guard on the whole batch, not just this variable (reproduced empirically).
export TRACK_BINOCLE_BIND_ADDR
# "1" when the Docker daemon runs rootless, else empty. Its root is the invoking user, and
# that user's own uid/gid has no mapping inside a container, so `--user $(id -u)` or a compose
# `user:` with it fails "cannot setuid to unmapped uid" (42 workstations, 2026-10-08 and
# 2026-10-17). Recursive, so `docker info` runs only when a recipe reads it.
DOCKER_ROOTLESS = $(shell docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && echo 1)
COMPOSE_PROFILES ?= dev
export COMPOSE_PROFILES COMPOSE_PROGRESS BUILDKIT_PROGRESS BUILDX_BUILDER DOCKER_BUILDKIT COMPOSE_DOCKER_CLI_BUILD COMPOSE_BAKE REGISTRY_CACHE_PREFIX
DOCKER_PULL_ATTEMPTS ?= 1
DOCKER_PULL_TIMEOUT ?= 120
DOCKER_PULL_KILL_AFTER ?= 15
DOCKER_PREFETCH_JOBS ?= 8
DOCKER_PREFETCH_SCOPE ?= all
COMPOSE_WAIT_TIMEOUT ?= 300
COMPOSE_WAIT_INTERVAL ?= 2
# Backend (postgres/gotrue/kong/postgrest/...) now lives in the standalone
# apps/grobase stack (docker project mini-baas). The root pipeline only owns the
# frontends, so the compose-wait lists carry frontend services only.
COMPOSE_HEALTHY_SERVICES ?= local-https-proxy osionos-bridge auth-gateway osionos-app opposite-osiris-web
COMPOSE_RUNNING_SERVICES ?=
COMPOSE_COMPLETED_SERVICES ?=
FRONTEND_DIR := apps/opposite-osiris
MAILPIT_IMAGE ?= axllent/mailpit:v1.22.3
BOOL ?= false
WEBSITE_URL := https://localhost:4322
OSIONOS_URL := https://localhost:3001
BRIDGE_URL := https://localhost:4000
AUTH_URL := https://localhost:8787/api/auth
DRAWNOSAURUS_URL := https://localhost:$(if $(DRAWNOSAURUS_HOST_PORT),$(DRAWNOSAURUS_HOST_PORT),3007)
# grobase's scripts/ops/resolve-ports.sh moves Kong to the next FREE host port when 8000 is
# already taken (an old stack still shutting down is enough), so a hardcoded 8000 fails the
# health gate against a backend that is perfectly healthy — measured: Kong published on 8001
# while this said 8000, and `make all` died at healthcheck after a clean build.
# Deferred (=) like BAAS_HEALTH_KEY below: resolved at recipe time, once the backend is up.
# A linked machine (make link, ssh or direct) runs no Kong of its own: the link's loopback copy
# on GROBASE_LINK_HOST_PORT answers there (0 = none), so `make healthcheck` probes the remote
# grobase instead of failing on a local 8000 nobody listens on (measured 2026-10-13).
# Falls back to 8000 when neither answers yet, so the message stays the obvious
# "could not connect to 8000" rather than a make error about an empty URL.
LINK_KONG_PORT = $(if $(filter ssh direct,$(shell bash scripts/grobase-link.sh mode 2>/dev/null)),$(filter-out 0,$(GROBASE_LINK_HOST_PORT)))
BAAS_PORT = $(or $(shell docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://'),$(LINK_KONG_PORT))
BAAS_URL = http://127.0.0.1:$(or $(BAAS_PORT),8000)
# grobase Kong gates /auth/v1/* with key-auth, so the BaaS health probe must
# present the anon apikey (read from the consolidated root .env.local).
# Deferred (=) not immediate (:=): on a fresh machine .env.local does not exist at parse
# time — `make all` pulls it mid-run (secrets-ensure) — so this must re-read at recipe time.
BAAS_HEALTH_KEY = $(shell grep -m1 -oE '^SB_KONG_KEY=.*' .env.local 2>/dev/null | cut -d= -f2-)
PLAYGROUND_VIEWER_URL := $(OSIONOS_URL)/playground-simulation/index.html
VSCODE_CLI ?= /usr/bin/code
GIT_COMMIT_MESSAGE ?= update
GIT_PUSH_REMOTE ?= origin
LOCAL_CERT_DIR ?= apps/grobase/certs
LOCAL_CA_CERT := $(LOCAL_CERT_DIR)/track-binocle-local-ca.pem
CERT_TRUST_MODE ?= system
CURL_HEALTH := curl --cacert $(LOCAL_CA_CERT) --retry 30 --retry-delay 2 --retry-all-errors --retry-connrefused -fsS

help:
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;39m        Track Binocle: Makefile Pipeline & Utilities         \033[0m"
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@printf "\033[1;38;5;45mUsage:\033[0m make [target]\n\n"
	@awk 'BEGIN { section = "" } /^[a-zA-Z0-9][^: ]*:/ { target=$$1; sub(":.*", "", target); getline; if ($$0 ~ /^## /) { desc = substr($$0, 4); if (desc ~ /^== /) { section = substr(desc, 4); printf("\n\033[1;38;5;220m%s\033[0m\n", section); } else { printf("  \033[1;38;5;81m%-22s\033[0m %s\n", target, desc); } } }' $(MAKEFILE_LIST)
	@echo -e "\033[1;38;5;39m───────────────────────────────────────────────────────────────\033[0m"
	@echo -e "\033[1;38;5;245mFor docs: make docs or see README.md\033[0m"

