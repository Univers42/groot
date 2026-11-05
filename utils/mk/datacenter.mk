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
endif

# On both paths, for every target: a target that saw another value would recreate the bridge and
# the edge on the other bind. Unset wherever the checkout's paths are readable, which is the
# compose default.
ifndef GROOT_READ_BINDS
GROOT_READ_BINDS := $(shell $(DATACENTER_SCRIPT) read-binds)
endif
ifneq ($(GROOT_READ_BINDS),)
export GROOT_READ_BINDS
endif

# The owner's `osionos connect` listens on 127.0.0.1:4100 and talks to production. While it is down
# that port looks free, and an edge that took it would keep it from coming back. public-up needs
# ./.env.public, so that file marks a host that serves production, whose ports stay as they are.
# Caveat: this covers the vault42 path only. `make all GROBASE_DATACENTER=` and `HOST_PORTS_KEEP_CLEAR=`
# still give a stopped connector's port to Mail, and a host that serves production with no
# ./.env.public beside its checkout would move Mail off 4100.
ifneq ($(DATACENTER_ON),)
ifeq ($(wildcard .env.public),)
export HOST_PORTS_KEEP_CLEAR ?= 4100
endif
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

datacenter-chain: ## Prove the ssh alias reaches this VM and its WAF answers with this VM's CA
## Reads the ports born2root recorded in ~/.config/born2root/<alias>-ports.env. With no record, the
## old default is used only once a certificate this VM's CA signed proves it. Reads only.
	@$(DATACENTER_SCRIPT) chain

datacenter-origins: ## Make the VM's grobase allow every frontend origin in .env.ports
## Usage: make datacenter-origins [DATACENTER_ALLOW_WRITES=1]
## Writes and recreates Kong, GoTrue and realtime only when a running list lacks an origin, and only
## on this user's own VM. Another alias is read and named, never written.
	@$(DATACENTER_SCRIPT) origins

datacenter-preflight: ## Check the VM, then only the writes those checks allow
## Armed realtime triggers run realtime-cdc-off alone. A models change takes a dump, reads it back in
## full, then applies. A key that does not verify stops, unless this run seeded the VM.
	@$(DATACENTER_SCRIPT) preflight

datacenter-binds: ## Write the agency roster from the VM, copy what an NFS checkout cannot serve
## Read-only in the VM. The copy exists only for an NFS checkout under rootless Docker.
	@$(DATACENTER_SCRIPT) binds

local-binds: ## Copy what an NFS checkout cannot serve, with no data center behind it
## Does nothing unless the checkout is on NFS under rootless Docker. frontends-up runs it.
	@$(DATACENTER_SCRIPT) local-binds

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
