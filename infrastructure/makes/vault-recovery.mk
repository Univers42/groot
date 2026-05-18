# Vault recovery targets.
admin-cred-lost:
## Regenerate a lost Fly Vault admin API key, publish env data, and mint reader/writer token files.
	@FLY_BIN='$(FLY_BIN)' FLY_VAULT_APP='$(FLY_VAULT_APP)' FLY_VAULT_URL='$(FLY_VAULT_URL)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' ADMIN_CRED_LOST_RECEIPT_FILE='$(ADMIN_CRED_LOST_RECEIPT_FILE)' VAULT_READER_TOKEN_FILE='$(VAULT_READER_TOKEN_FILE)' VAULT_WRITER_TOKEN_FILE='$(VAULT_WRITER_TOKEN_FILE)' bash apps/baas/scripts/vault-admin-cred-lost.sh
	@set -eu; set -a; . '$(VAULT_ADMIN_TOKEN_FILE)'; set +a; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_PUBLIC_ADDR='$(FLY_VAULT_URL)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs publish; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL='$(VAULT_READER_TOKEN_TTL)' VAULT_TEAM_TOKEN_FILE='$(VAULT_READER_TOKEN_FILE)' VAULT_PUBLIC_ADDR='$(FLY_VAULT_URL)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs team-token; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_TEAM_ROLE=writer VAULT_TOKEN_TTL='$(VAULT_WRITER_TOKEN_TTL)' VAULT_TEAM_TOKEN_FILE='$(VAULT_WRITER_TOKEN_FILE)' VAULT_PUBLIC_ADDR='$(FLY_VAULT_URL)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs team-token
	$(MAKE) vault-status-shared VAULT_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)'
	@echo '[vault-admin] recovery complete: admin, reader, and writer token files are under .vault/ with private permissions.'

vault-fly-reset:
## Destructively recreate the Fly-hosted Vault and republish managed env data. Requires VAULT_FLY_RESET_CONFIRM=destroy-track-binocle-vault.
	@if [[ '$(VAULT_FLY_RESET_CONFIRM)' != '$(VAULT_FLY_RESET_PHRASE)' ]]; then \
		echo '[vault] destructive Fly Vault reset refused.'; \
		echo '[vault] This deletes the shared Vault service boundary and replaces its admin credentials.'; \
		echo '[vault] Rerun only as the owner with: make vault-fly-reset VAULT_FLY_RESET_CONFIRM=$(VAULT_FLY_RESET_PHRASE)'; \
		exit 1; \
	fi
	@command -v '$(FLY)' >/dev/null 2>&1 || { echo '[vault] $(FLY) is required for Fly Vault reset.'; exit 1; }
	@set -eu; \
		echo '[vault] destroying Fly app $(FLY_VAULT_APP); old Vault root/unseal material and env records become unrecoverable unless separately backed up'; \
		if $(FLY) status --app '$(FLY_VAULT_APP)' >/dev/null 2>&1; then \
			$(FLY) apps destroy '$(FLY_VAULT_APP)' --yes; \
		else \
			echo '[vault] Fly app $(FLY_VAULT_APP) is not reachable; continuing with fresh create'; \
		fi; \
		rm -f .vault/fly-vault-root-token .vault/track-binocle-reader.env .vault/track-binocle-writer.env
	$(MAKE) vault-fly