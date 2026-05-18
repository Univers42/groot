# Vault session token targets and compatibility aliases.
vault-session-reader-token: vault-session-node-check
## Mint a reader invite token from the current admin-capable Vault session.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL='$(VAULT_READER_TOKEN_TTL)' VAULT_TEAM_TOKEN_FILE='$(VAULT_READER_TOKEN_FILE)' node apps/baas/scripts/vault-session.mjs team-token

vault-session-writer-token: vault-session-node-check
## Mint a writer invite token from the current admin-capable Vault session.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_TEAM_ROLE=writer VAULT_TOKEN_TTL='$(VAULT_WRITER_TOKEN_TTL)' VAULT_TEAM_TOKEN_FILE='$(VAULT_WRITER_TOKEN_FILE)' node apps/baas/scripts/vault-session.mjs team-token

get-secrets: vault-get-secrets
logout: vault-logout