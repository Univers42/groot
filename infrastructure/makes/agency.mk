# ──────────────────────────────────────────────────────────────────────────────
# agency.mk — Binocle Intelligence Agency simulation lifecycle
#
# Seeds and verifies the full organization simulation: owner + 20 employees,
# the permanent `agency` live tenant (10 case-file tables + edges, ~950 rows),
# ABAC roles/policies in both engines, wiki/chat content, and the Playwright
# end-to-end simulation. Everything talks to the RUNNING stacks via docker
# exec/curl — stack lifecycle stays with `make all` / the BaaS Makefile.
# ──────────────────────────────────────────────────────────────────────────────

AGENCY_SEEDS_DIR  := tools/seeds
AGENCY_INFRA_DIR  := apps/baas/mini-baas-infra

.PHONY: agency-people agency-seed agency-policies agency-content agency-verify agency-sim agency-all

agency-people: ## Agency: create owner + 20 employees (gotrue, bridge identities, org workspace)
	bash $(AGENCY_SEEDS_DIR)/seed_agency_people.sh

agency-seed: ## Agency: provision the live tenant + 10 tables + edges, seed ~950 rows
	bash $(AGENCY_INFRA_DIR)/scripts/seed/agency-tenant.sh
	python3 $(AGENCY_SEEDS_DIR)/seed_agency.py
	docker exec -i mini-baas-postgres psql -U postgres -d agency -v ON_ERROR_STOP=1 -q < $(AGENCY_SEEDS_DIR)/seed_agency.sql
	@echo "agency tenant seeded (see $(AGENCY_INFRA_DIR)/.agency-tenant.env)"

agency-policies: ## Agency: seed ABAC roles + policies (permission-engine + osionos defaults)
	bash $(AGENCY_INFRA_DIR)/scripts/seed/agency-policies.sh

agency-content: ## Agency: seed wikis, galleries, teamspaces, channels + feed backfill
	python3 $(AGENCY_SEEDS_DIR)/seed_agency_wiki.py
	docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < $(AGENCY_SEEDS_DIR)/seed_agency_wiki.sql
	@if [ -f $(AGENCY_SEEDS_DIR)/seed_agency_chat.sql ]; then \
		docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < $(AGENCY_SEEDS_DIR)/seed_agency_chat.sql; \
	fi

agency-verify: ## Agency: run the m23 foundation gate (tables, accounts, policy decisions)
	bash $(AGENCY_INFRA_DIR)/scripts/verify/m23-agency-foundation.sh

agency-sim: ## Agency: run the Playwright end-to-end organization simulation
	docker compose --profile testing run --rm agency-simulation

agency-all: agency-people agency-seed agency-policies agency-verify ## Agency: full foundation (people → tenant/data → policies → gate)
	@echo "agency foundation complete"
