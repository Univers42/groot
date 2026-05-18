env-format:
	$(NODE_RUN) apps/baas/scripts/vault-env.mjs format

env-fetch: vault-up
	$(VAULT_ENV_CMD) fetch

env-backup:
	$(NODE_RUN) apps/baas/scripts/vault-env.mjs backup

env-restore-test: vault-seed
	$(VAULT_ENV_CMD) roundtrip
