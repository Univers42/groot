# Top-level pipeline targets.
# The BaaS backend now runs as the standalone apps/grobase stack (docker project
# mini-baas). The root pipeline regenerates certs (via grobase), guards that the
# grobase backend is up, brings up the root FRONTENDS only, then healthchecks.
all: sync-submodules-soft secrets-ensure certs certs-trust-local backend-up env-local-ensure restore-if-empty frontends-up healthcheck showcase
## FROM-ZERO self-provisioning: sync submodules to latest → pull secrets from vault42 (or, with NO vault key, grobase self-generates them) → certs → START the grobase backend if down → derive root ./.env.local locally when absent (no-vault mode) → restore all-engine data IF fresh (fail-safe no-op otherwise) → build+start frontends → verify → clickable recap. A clean clone + `make all` reconstitutes the whole machine — with the vault key it restores the SHARED secrets+data, without it everything is generated locally.

all-local: sync-submodules-soft secrets-ensure certs certs-trust-local backend-up env-local-ensure restore-if-empty frontends-up healthcheck showcase
## Same self-provisioning pipeline; alias kept for callers that used all-local.

sync-submodules-soft:
## Best-effort recursive submodule sync to latest (ff-only, skips dirty) so `make all` always builds the newest code. NEVER blocks the pipeline — network/sync hiccups just print a note and continue. Skipped entirely with SKIP_SYNC=1.
	@if [ "$(SKIP_SYNC)" = "1" ]; then \
		printf '[make all] SKIP_SYNC=1 — not syncing submodules\n'; \
	else \
		$(MAKE) --no-print-directory syncro-submodule \
			|| printf '[make all] submodule sync skipped/partial (offline or diverged) — continuing with the current checkout\n'; \
	fi

local: backend-up up-local
## Lean LOCAL edition (single machine): pages over plain HTTP on :4000. Frontends only; the grobase backend must already be running.

docs:
## Show the primary Docker pipeline documentation files.
	@printf 'Read README.md and docs/howtouse.md for the Docker-only pipeline workflow.\n'

rebuild-server:
## Run the host rebuild daemon (127.0.0.1:7799) so the osionos Update button can rebuild the stack (make all) on click. Leave it running in a terminal.
	@python3 scripts/dev-rebuild-server.py