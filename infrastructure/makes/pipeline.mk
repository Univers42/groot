# Top-level pipeline targets.
all: env-fetch-shared pulls certs certs-trust-local certs-trust-browser-host bootstrap env-format docker-prefetch-images vault-seed vault-verify-approles env-fetch up healthcheck showcase
## Build, start, and verify the complete Vault-backed Track Binocle pipeline.

all-local: pulls certs certs-trust-local certs-trust-browser-host bootstrap env-format docker-prefetch-images vault-seed vault-verify-approles env-fetch up healthcheck showcase
## Build the local generated-secret pipeline without shared Vault credentials.

local: bootstrap env-format docker-prefetch-images vault-seed vault-verify-approles env-fetch up-local
## Lean LOCAL edition (single machine): DB + auth + pages over plain HTTP on :4000. Real local login, locally-generated secrets, NO TLS/CA, NO website/mail/calendar/mini-baas. The desktop app talks to http://localhost:4000.

bootstrap:
	$(NODE_RUN) apps/baas/scripts/bootstrap.mjs

docs:
## Show the primary Docker pipeline documentation files.
	@printf 'Read README.md and docs/howtouse.md for the Docker-only pipeline workflow.\n'