# ──────────────────────────────────────────────────────────────────────────────
# gourmand.mk — Vite & Gourmand client-onboarding lifecycle
#
# Mounts the restaurant's REAL PostgreSQL (Supabase) as a tenant_owned live
# mount, mirrors their staff into the "Vite & Gourmand" org workspace, seeds
# the workspace content (live pages, wikis, chat), and verifies the whole
# path. The client DSN comes from vite-gourmand's own Bitwarden flow:
#   cd apps/vite-gourmand && make secrets      (writes Back/.env, interactive)
# or export GOURMAND_DB_DSN. Stack lifecycle stays with `make all` / the BaaS
# Makefile; everything here talks to the RUNNING stacks.
# ──────────────────────────────────────────────────────────────────────────────

GOURMAND_SEEDS_DIR := tools/seeds
GOURMAND_INFRA_DIR := apps/baas/mini-baas-infra

.PHONY: gourmand-mount gourmand-people gourmand-content gourmand-env gourmand-verify gourmand-all

gourmand-mount: ## Gourmand: register their DB as a tenant_owned live mount (+schema assert)
	bash $(GOURMAND_INFRA_DIR)/scripts/seed/gourmand-tenant.sh

gourmand-people: ## Gourmand: mirror their real staff (User⋈Role) into the org workspace
	bash $(GOURMAND_SEEDS_DIR)/seed_gourmand_people.sh

gourmand-content: ## Gourmand: seed the workspace (live pages, wikis, chat channels)
	@set -e; \
	. $(GOURMAND_INFRA_DIR)/.gourmand-tenant.env; \
	eval "$$(grep -E '^GOURMAND_(ORG_WORKSPACE_ID|OWNER_UUID)=' $(GOURMAND_SEEDS_DIR)/.gourmand-people.env)"; \
	python3 $(GOURMAND_SEEDS_DIR)/seed_gourmand_content.py \
	  "$$GOURMAND_ORG_WORKSPACE_ID" "$$GOURMAND_OWNER_UUID" "$$GOURMAND_DB_ID" \
	  "$(GOURMAND_SEEDS_DIR)/.gourmand-people.env" \
	| docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q

gourmand-env: ## Gourmand: append the mount to the app's VITE_BAAS_LIVE_MOUNTS fallback
	@set -e; \
	. $(GOURMAND_INFRA_DIR)/.gourmand-tenant.env; \
	GOURMAND_DB_ID="$$GOURMAND_DB_ID" python3 $(GOURMAND_SEEDS_DIR)/gourmand_app_env.py apps/osionos/app/.env

gourmand-verify: ## Gourmand: run the m24 gates (tenant_owned + live mount + workspace)
	bash $(GOURMAND_INFRA_DIR)/scripts/verify/m24-gourmand.sh

gourmand-sim: ## Gourmand: Playwright staff e2e (mirrored owner signs in, works the live data)
	@set -e; \
	CRED="$$(grep -m1 '|owner|' $(GOURMAND_SEEDS_DIR)/.gourmand-people.env | cut -d= -f2-)"; \
	docker compose --profile testing run --rm \
	  -e GOURMAND_E2E_EMAIL="$$(echo "$$CRED" | cut -d'|' -f1)" \
	  -e GOURMAND_E2E_PASSWORD="$$(echo "$$CRED" | cut -d'|' -f5)" \
	  playground-simulation node scripts/gourmand-staff-verification.mjs

gourmand-all: gourmand-mount gourmand-people gourmand-content gourmand-verify ## Gourmand: full onboarding chain
	@echo "Vite & Gourmand onboarding complete — rebuild the app with: make osionos-app-live"
