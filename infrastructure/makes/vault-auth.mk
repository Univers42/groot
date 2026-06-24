# Vault auth maintenance targets.
vault-github-oidc:
## Deprecated at root: Vault GitHub-OIDC config now lives in apps/grobase.
	@echo "[skip] vault-github-oidc now lives in apps/grobase"

vault-rotate-approles: vault-up
## Rotate service AppRole secret IDs and store the new IDs in Vault.
	$(VAULT_ENV_CMD) rotate-approles

vault-verify-approles: vault-up
	$(VAULT_ENV_CMD) verify-approles