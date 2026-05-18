# Vault auth maintenance targets.
vault-github-oidc: vault-policy-sync
## Configure Vault JWT auth so GitHub Actions can fetch managed env secrets through OIDC.
	$(VAULT_COMPOSE) run --rm -e VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' -e VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' -e VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' -e VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' -e VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' -e VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' -e VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' vault-env node apps/baas/scripts/vault-env.mjs sync-github-oidc

vault-rotate-approles: vault-up
## Rotate service AppRole secret IDs and store the new IDs in Vault.
	$(VAULT_ENV_CMD) rotate-approles

vault-verify-approles: vault-up
	$(VAULT_ENV_CMD) verify-approles