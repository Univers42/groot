# Vault session authentication targets.
vault-session-node-check:
## Check that host Node.js is available for Vault session commands.
	@command -v node >/dev/null 2>&1 || { echo '[vault-session] host Node.js is required for Vault session targets.'; exit 1; }

vault-session-check: vault-session-node-check
## Check Vault session tooling, token files, and configured auth defaults without printing secrets.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_ADMIN_TOKEN_FILE='$(VAULT_ADMIN_TOKEN_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' FLY_VAULT_APP='$(FLY_VAULT_APP)' FLY_VAULT_URL='$(FLY_VAULT_URL)' node apps/baas/scripts/vault-session.mjs check

vault-login-user: vault-session-node-check
## Authenticate a developer session through Vault GitHub auth by default, or OIDC with VAULT_USER_AUTH_METHOD=oidc.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_USER_AUTH_METHOD='$(VAULT_USER_AUTH_METHOD)' VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' node apps/baas/scripts/vault-session.mjs login-user

vault-login-approle: vault-session-node-check
## Authenticate a machine session with AppRole role-id and secret-id files or env vars.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_APPROLE_AUTH_PATH='$(VAULT_APPROLE_AUTH_PATH)' VAULT_ROLE_ID_FILE='$(VAULT_ROLE_ID_FILE)' VAULT_SECRET_ID_FILE='$(VAULT_SECRET_ID_FILE)' node apps/baas/scripts/vault-session.mjs login-approle

vault-login-jwt: vault-session-node-check
## Authenticate a CI/cloud session by exchanging JWT_TOKEN for a short-lived Vault token.
	@VAULT_ADDR='$(VAULT_SESSION_ADDR)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_SESSION_FILE='$(VAULT_SESSION_FILE)' VAULT_CLI_TOKEN_FILE='$(VAULT_CLI_TOKEN_FILE)' VAULT_JWT_AUTH_PATH='$(VAULT_JWT_AUTH_PATH)' VAULT_JWT_ROLE='$(VAULT_JWT_ROLE)' node apps/baas/scripts/vault-session.mjs login-jwt