# Shared Vault repair target.
vault-repair-shared: env-format
## Publish complete local env files to shared Vault with a writer token, then verify coverage.
	$(MAKE) vault-publish-shared VAULT_PUBLISH_TOKEN_FILE='$(VAULT_PUBLISH_TOKEN_FILE)' VAULT_TOKEN_FILE='$(VAULT_TOKEN_FILE)'
	$(MAKE) vault-status-shared VAULT_TOKEN_FILE='$(VAULT_PUBLISH_TOKEN_FILE)'