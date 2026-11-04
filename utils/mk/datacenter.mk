# `make all` on a machine with vault42 credentials: the frontends are built and started here, and
# grobase stays in the VM on this host, reached over verified TLS (ADR 0047). groot starts no
# grobase on this path. scripts/datacenter.sh holds the steps; the local pipeline in pipeline.mk
# stays what a machine without credentials runs (CI, a clean evaluation machine).
DATACENTER_SCRIPT = GROBASE_LINK_DIR='$(GROBASE_LINK_DIR)' bash scripts/datacenter.sh

ifneq ($(strip $(GROBASE_DATACENTER)),)
# Exported so every link target on this machine reads the same settings. Neither file is the
# vault's: .env.grobase-link holds the shared tailnet target and a team push publishes it, while
# a `*.local` name is private to the pusher.
export GROBASE_DATACENTER
export GROBASE_LINK_CONF ?= $(CURDIR)/.env.grobase-link.local
export GROBASE_REMOTE_ENV ?= $(CURDIR)/.env.grobase-datacenter.local
endif

##@ Pipeline
datacenter-secrets: ## Pull the vault's tree when a required file is missing
## Usage: make datacenter-secrets [VAULT42_REFRESH=1]
## Skipped when ./.env.local, apps/grobase/.env and the certificate archive are here: every pull
## swaps differing files and keeps .bak-<stamp> copies. The prod environment only, not volumes.
	@if $(DATACENTER_SCRIPT) vault-needed; then \
		VAULT42_ENVS='$(or $(VAULT42_ENVS),$(VAULT42_ENV))' $(MAKE) --no-print-directory vault42-pull-everything YES=1; \
	fi

datacenter-certs: ## Restore the CA certificate and the edge leaf from the vault, never the CA key
	@$(DATACENTER_SCRIPT) certs

datacenter-configure: ## Check the data center VM, pin its host key, write the link's settings
	@$(DATACENTER_SCRIPT) configure

datacenter-preflight: ## Read-only checks of the VM, then only the writes they allow
## Usage: make datacenter-preflight [DATACENTER_MIGRATE=1]
## Armed realtime triggers run realtime-cdc-off alone. Pending DDL stops unless DATACENTER_MIGRATE=1,
## which dumps postgres and verifies the dump first. A key that does not verify always stops.
	@$(DATACENTER_SCRIPT) preflight

datacenter-trust: ## Prove the CA signs the VM's WAF, then import it in every browser store
	@$(DATACENTER_SCRIPT) trust

datacenter-browsers: ## Relaunch the browsers if a store changed (GROOT_NO_BROWSER_RESTART=1 skips)
	@$(DATACENTER_SCRIPT) browsers
