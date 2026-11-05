# Top-level pipeline targets.
# The BaaS backend now runs as the standalone apps/grobase stack (docker project
# mini-baas). The root pipeline regenerates certs (via grobase), guards that the
# grobase backend is up, brings up the root FRONTENDS only, then healthchecks.
##@ Pipeline
# Vault42 credentials on this machine turn `all` into the data-center deployment (datacenter.mk,
# ADR 0047). `make all GROBASE_DATACENTER=` takes this local path anyway.
GROBASE_DATACENTER ?= $(shell bash scripts/datacenter.sh setting)
# `local` is the opt-out in a credential file, so it means the same on the command line.
DATACENTER_ON := $(filter-out local,$(strip $(GROBASE_DATACENTER)))
# The gate also runs on a machine that resolved to no data center by itself, so half-set credentials
# stop instead of silently taking the local path. Naming the setting for one run skips it.
ALL_GATE := $(if $(or $(DATACENTER_ON),$(filter file,$(origin GROBASE_DATACENTER))),datacenter-gate)
ifeq ($(DATACENTER_ON),)
ALL_STEPS := secrets-ensure certs certs-trust-local backend-up env-local-ensure restore-if-empty demo-login-ensure models-migrate live-data-ensure mounts-reencrypt frontends-up healthcheck showcase
else
ALL_STEPS := datacenter-secrets datacenter-vm datacenter-configure datacenter-certs link datacenter-preflight datacenter-roster link-demo-login-ensure datacenter-trust link-frontends-start datacenter-apps link-healthcheck datacenter-health datacenter-verify showcase datacenter-browsers
endif
all: $(ALL_GATE) sync-submodules-soft $(ALL_STEPS) ## Provision a fresh machine end to end: secrets, certs, backend, frontends, checks
## Usage: make all [SKIP_SYNC=1] [GROBASE_EDITION=devlean|migrate|full] [PULL_PREBUILT=1]
## FROM-ZERO self-provisioning: sync submodules to latest → pull secrets from vault42 (or, with NO
## vault key, grobase self-generates them) → certs → START the grobase backend if down → derive root
## ./.env.local locally when absent (no-vault mode) → restore all-engine data IF fresh (fail-safe
## no-op otherwise) → set the demo account's password from ./.env.local → build+start frontends →
## verify → clickable recap. A clean clone + `make all` reconstitutes the whole machine — with the
## vault key it restores the SHARED secrets+data, without it everything is generated locally.
## With vault42 credentials on this machine, `all` deploys against the data center VM instead and
## starts no grobase: wiki/runbooks/datacenter.md.

link-all: ## Pull vault42 secrets, check the tailnet path to grobase, build against it
## Usage: make link-all [GROBASE_TARGET=https://<host>.<tailnet>.ts.net] [VAULT42_ENVS="prod …"]
## `make all` for a machine whose grobase runs elsewhere, in three steps that each stop the run:
## (1) pulls $(VAULT42_ORG)/$(VAULT42_PROJECT)/$(VAULT42_ENV) from vault42 without asking; the volumes
## environment is left out unless VAULT42_ENVS names it. The credentials come from the environment
## or ~/.config/42ctl/secret*: FT_PASSPHRASE, FT_PASSWORD, FT_EMAIL, FT_TENANT. (2) link-paths: this
## device on the tailnet, the peer online, Kong answering with a verified certificate — a FAIL row
## names the repair. (3) link-frontends-start: opens the link, builds and starts the frontends and
## verifies them; nothing is written to the data center (link-frontends-up converges it).
	@VAULT42_ENVS='$(or $(VAULT42_ENVS),$(VAULT42_ENV))' $(MAKE) --no-print-directory vault42-pull-everything YES=1
	@$(MAKE) --no-print-directory link-paths || { \
		printf '[link-all] grobase is not reachable: repair the FAIL rows above, then re-run make link-all\n' >&2; \
		exit 1; }
	@$(MAKE) --no-print-directory link-frontends-start

sync-submodules-soft: ## Sync submodules to latest, best effort; never blocks the pipeline
## Usage: make sync-submodules-soft [SKIP_SYNC=1]
## Best-effort recursive submodule sync to latest (ff-only, skips dirty) so `make all` always builds
## the newest code. NEVER blocks the pipeline — network/sync hiccups just print a note and continue.
## Skipped entirely with SKIP_SYNC=1.
	@if [ "$(SKIP_SYNC)" = "1" ]; then \
		printf '[make all] SKIP_SYNC=1 — not syncing submodules\n'; \
	else \
		$(MAKE) --no-print-directory syncro-submodule \
			|| printf '[make all] submodule sync skipped/partial (offline or diverged) — continuing with the current checkout\n'; \
	fi

rebuild-server: ## Run the host rebuild daemon on 127.0.0.1:7799 for the osionos Update button
## Run the host rebuild daemon (127.0.0.1:7799) so the osionos Update button can rebuild the stack
## (make all) on click. Leave it running in a terminal.
	@python3 scripts/dev-rebuild-server.py
