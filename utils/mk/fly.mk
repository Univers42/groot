vault-fly-create:
## Create the Fly app and persistent Vault volume when missing.
	@$(FLY) apps create $(FLY_VAULT_APP) --org personal || true
	@$(FLY) volumes list --app $(FLY_VAULT_APP) | grep -q '$(FLY_VAULT_VOLUME)' || $(FLY) volumes create $(FLY_VAULT_VOLUME) --app $(FLY_VAULT_APP) --region $(FLY_VAULT_REGION) --size 1 --yes

vault-fly-deploy:
## Deprecated at root: Fly Vault deploy now lives in apps/grobase.
	@echo "[skip] vault-fly-deploy now lives in apps/grobase"

vault-fly-publish:
## Deprecated at root: Fly Vault publish/GitHub-OIDC sync now lives in apps/grobase.
	@echo "[skip] vault-fly-publish now lives in apps/grobase"

vault-fly-github:
## Point GitHub Actions at the public Fly Vault URL.
	@gh variable set TRACK_BINOCLE_VAULT_ADDR --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(FLY_VAULT_URL)'
	@gh variable set TRACK_BINOCLE_VAULT_AUTH_PATH --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_AUTH_PATH)'
	@gh variable set TRACK_BINOCLE_VAULT_ROLE --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_ROLE)'
	@gh variable set TRACK_BINOCLE_VAULT_ENV_PREFIX --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_ENV_PREFIX)'

vault-fly: vault-fly-create vault-fly-deploy vault-fly-publish vault-fly-github
## Create, deploy, publish, and wire GitHub Actions to the Fly-hosted Vault.
