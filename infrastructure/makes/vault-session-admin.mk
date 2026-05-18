# Vault session operation targets.
vault-login-fly-admin: vault-session-node-check
## Create a short-lived admin session from Fly operator access and FLY_API_TOKEN in env or ignored env files.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' FLY_VAULT_APP='$(FLY_VAULT_APP)' FLY_VAULT_URL='$(FLY_VAULT_URL)' FLY_BIN='$(FLY_BIN)' VAULT_ADMIN_TOKEN_TTL='$(VAULT_ADMIN_TOKEN_TTL)' node apps/baas/scripts/vault-session.mjs login-fly-admin

vault-session-status: vault-session-node-check
## Show current Vault session metadata without printing the token.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' node apps/baas/scripts/vault-session.mjs status

vault-get-secrets: vault-session-node-check
## Fetch managed Track Binocle env secrets using the current Vault session.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' node apps/baas/scripts/vault-session.mjs fetch

vault-kv-export: vault-session-node-check
## Export VAULT_SECRET_PATH as JSON to VAULT_SECRET_OUTPUT under .vault by default.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_SECRET_PATH='$(VAULT_SECRET_PATH)' VAULT_SECRET_OUTPUT='$(VAULT_SECRET_OUTPUT)' node apps/baas/scripts/vault-session.mjs export-secret

vault-logout: vault-session-node-check
## Revoke the active Vault session and remove local session token files.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' node apps/baas/scripts/vault-session.mjs logout