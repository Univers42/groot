# Top-level pipeline targets.
# The BaaS backend now runs as the standalone apps/grobase stack (docker project
# mini-baas). The root pipeline regenerates certs (via grobase), guards that the
# grobase backend is up, brings up the root FRONTENDS only, then healthchecks.
all: certs certs-trust-local backend-up frontends-up healthcheck showcase
## Regenerate certs, guard the grobase backend, start the root frontends, and verify.

all-local: certs certs-trust-local backend-up frontends-up healthcheck showcase
## Same frontends-on-grobase pipeline; alias kept for callers that used all-local.

local: backend-up up-local
## Lean LOCAL edition (single machine): pages over plain HTTP on :4000. Frontends only; the grobase backend must already be running.

bootstrap:
## Deprecated: bootstrap/secrets generation moved to the apps/grobase stack.
	@echo "[skip] bootstrap now lives in apps/grobase"

docs:
## Show the primary Docker pipeline documentation files.
	@printf 'Read README.md and docs/howtouse.md for the Docker-only pipeline workflow.\n'

rebuild-server:
## Run the host rebuild daemon (127.0.0.1:7799) so the osionos Update button can rebuild the stack (make all) on click. Leave it running in a terminal.
	@python3 scripts/dev-rebuild-server.py