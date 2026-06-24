# Vault recovery targets.
admin-cred-lost:
## Deprecated at root: Fly Vault admin recovery now lives in apps/grobase.
	@echo "[skip] admin-cred-lost now lives in apps/grobase"

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