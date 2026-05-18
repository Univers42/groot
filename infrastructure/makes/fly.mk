vault-fly-create:
## Create the Fly app and persistent Vault volume when missing.
	@$(FLY) apps create $(FLY_VAULT_APP) --org personal || true
	@$(FLY) volumes list --app $(FLY_VAULT_APP) | grep -q '$(FLY_VAULT_VOLUME)' || $(FLY) volumes create $(FLY_VAULT_VOLUME) --app $(FLY_VAULT_APP) --region $(FLY_VAULT_REGION) --size 1 --yes

vault-fly-deploy:
## Deploy the public Vault service to Fly.io.
	@cd apps/baas/mini-baas-infra/docker/services/vault && $(FLY) deploy --app $(FLY_VAULT_APP) --config fly.toml --remote-only

vault-fly-publish:
## Publish managed env data and GitHub auth configuration to the Fly Vault.
	@mkdir -p .vault
	@set -eu; token_file='.vault/fly-vault-root-token'; trap 'rm -f "$$token_file"' EXIT; \
		$(FLY) ssh console --app $(FLY_VAULT_APP) --command 'jq -r .root_token /vault/data/.vault-keys.json' > "$$token_file"; \
		chmod 600 "$$token_file"; \
		token="$$(tr -d '\r\n' < "$$token_file")"; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_TOKEN="$$token" VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs publish; \
		VAULT_ADDR='$(FLY_VAULT_URL)' VAULT_NAMESPACE='$(VAULT_NAMESPACE)' VAULT_TOKEN="$$token" VAULT_ENV_PREFIX='$(VAULT_ENV_PREFIX)' VAULT_GITHUB_OIDC_AUTH_PATH='$(VAULT_GITHUB_OIDC_AUTH_PATH)' VAULT_GITHUB_OIDC_ROLE='$(VAULT_GITHUB_OIDC_ROLE)' VAULT_GITHUB_OIDC_REPOSITORY='$(VAULT_GITHUB_OIDC_REPOSITORY)' VAULT_GITHUB_OIDC_AUDIENCE='$(VAULT_GITHUB_OIDC_AUDIENCE)' VAULT_GITHUB_AUTH_PATH='$(VAULT_GITHUB_AUTH_PATH)' VAULT_GITHUB_ORG='$(VAULT_GITHUB_ORG)' VAULT_GITHUB_TEAM='$(VAULT_GITHUB_TEAM)' $(DOCKER_NODE_VAULT) node apps/baas/scripts/vault-env.mjs sync-github-oidc

vault-fly-github:
## Point GitHub Actions at the public Fly Vault URL.
	@gh variable set TRACK_BINOCLE_VAULT_ADDR --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(FLY_VAULT_URL)'
	@gh variable set TRACK_BINOCLE_VAULT_AUTH_PATH --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_AUTH_PATH)'
	@gh variable set TRACK_BINOCLE_VAULT_ROLE --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_GITHUB_OIDC_ROLE)'
	@gh variable set TRACK_BINOCLE_VAULT_ENV_PREFIX --repo $(VAULT_GITHUB_OIDC_REPOSITORY) --body '$(VAULT_ENV_PREFIX)'

vault-fly: vault-fly-create vault-fly-deploy vault-fly-publish vault-fly-github
## Create, deploy, publish, and wire GitHub Actions to the Fly-hosted Vault.
