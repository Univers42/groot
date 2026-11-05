# `make all` on a machine with vault42 credentials: the frontends are built and started here, and
# grobase stays in the VM on this host, reached over verified TLS (ADR 0047). groot starts no
# grobase on this path. scripts/datacenter.sh holds the steps; the local pipeline in pipeline.mk
# stays what a machine without credentials runs (CI, a clean evaluation machine).
DATACENTER_SCRIPT = GROBASE_LINK_DIR='$(GROBASE_LINK_DIR)' bash scripts/datacenter.sh

ifneq ($(DATACENTER_ON),)
# Exported so every link target on this machine reads the same settings. Neither file is the
# vault's: .env.grobase-link holds the shared tailnet target and a team push publishes it, while
# a `*.local` name is private to the pusher.
export GROBASE_DATACENTER
export GROBASE_LINK_CONF ?= $(CURDIR)/.env.grobase-link.local
export GROBASE_REMOTE_ENV ?= $(CURDIR)/.env.grobase-datacenter.local
ifndef GROOT_READ_BINDS
GROOT_READ_BINDS := $(shell $(DATACENTER_SCRIPT) read-binds)
endif
export GROOT_READ_BINDS
endif

##@ Pipeline
datacenter-gate: ## Prove the vault can be read, or stop naming what to set
## Usage: make datacenter-gate
## First step of make all. No credentials at all is the local pipeline; some but not all stops.
	@$(DATACENTER_SCRIPT) gate

datacenter-secrets: ## Pull the vault's tree when a required file is missing
## Usage: make datacenter-secrets [VAULT42_REFRESH=1]
## Skipped when ./.env.local and apps/grobase/.env are here: every pull swaps differing files and
## keeps .bak-<stamp> copies. The prod environment only, not volumes.
	@if $(DATACENTER_SCRIPT) vault-needed; then \
		VAULT42_ENVS='$(or $(VAULT42_ENVS),$(VAULT42_ENV))' $(MAKE) --no-print-directory vault42-pull-everything YES=1; \
	fi

datacenter-vm: ## Wait for the VM, have born2root start grobase in it, seed an empty platform
## Usage: make datacenter-vm [DATACENTER_ALLOW_WRITES=1]
## Autostart keeps the VM up. groot builds it only when it provably does not exist, from a terminal
## (DATACENTER_ALLOW_WRITES does not unlock that). A stopped grobase goes through born2root's make
## grobase, never a bare make up. Other writes need a terminal, or DATACENTER_ALLOW_WRITES=1.
	@$(DATACENTER_SCRIPT) vm

datacenter-configure: ## Pin the VM's host key, write the link's settings
	@$(DATACENTER_SCRIPT) configure

datacenter-certs: ## Copy the CA certificate and the WAF's leaf from the VM, never the CA key
	@$(DATACENTER_SCRIPT) certs

datacenter-preflight: ## Check the VM, then only the writes those checks allow
## Armed realtime triggers run realtime-cdc-off alone. A models change takes a dump, reads it back in
## full, then applies. A key that does not verify stops, unless this run seeded the VM.
	@$(DATACENTER_SCRIPT) preflight

datacenter-binds: ## Write the agency roster from the VM, copy what an NFS checkout cannot serve
## Read-only in the VM. The copy exists only for an NFS checkout under rootless Docker.
	@$(DATACENTER_SCRIPT) binds

datacenter-trust: ## Prove the CA signs the VM's WAF, then import it in every browser store
	@$(DATACENTER_SCRIPT) trust

datacenter-apps: ## Start Mail and Calendar: opt-in elsewhere, part of the deployment here
## Their Google sign-in needs a public domain, so on localhost they open without it.
	@$(LINK_COMPOSE_ENV) $(MAKE) --no-print-directory mail-up calendar-up

datacenter-health: ## born2root's verdict on the platform, its reach and its forwards
	@$(DATACENTER_SCRIPT) health

datacenter-verify: ## Prove the plan, the pages, the mounts and the browsers
## Usage: make datacenter-verify [DATACENTER_VERIFY_BROWSERS=1]
## Fails on anything less than the VM's whole plan healthy. The browsers need a terminal or the
## setting, and print SKIP otherwise: the Update button runs make all with no terminal.
	@$(LINK_COMPOSE_ENV) $(DATACENTER_SCRIPT) verify

datacenter-browsers: ## Relaunch the browsers if a store changed (GROOT_NO_BROWSER_RESTART=1 skips)
	@$(DATACENTER_SCRIPT) browsers

dc-%: ## Run a grobase target in the VM: dc-ps, dc-logs, dc-health, dc-up
## Usage: make dc-health
## An allowlist: dc-up goes through born2root, anything else is refused, CONFIRM is never forwarded.
	@$(DATACENTER_SCRIPT) dc '$*'
