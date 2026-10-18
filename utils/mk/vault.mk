vault-up: certs
	@mkdir -p .vault
	@if [ -f $(VAULT_UP_STAMP) ] && $(VAULT_COMPOSE) ps --status running --quiet vault 2>/dev/null | grep -q .; then \
		echo '[vault] already up, skipping init'; \
	else \
		$(MAKE) docker-prefetch-images DOCKER_PREFETCH_SCOPE=vault; \
		$(MAKE) compose-build BAKE_GROUP=secrets BAKE_TARGETS='vault'; \
		docker compose rm -sf local-https-proxy >/dev/null 2>&1 || true; \
		$(VAULT_COMPOSE) up -d --no-build --pull never vault local-https-proxy; \
		$(VAULT_COMPOSE) run --rm vault-init; \
		touch $(VAULT_UP_STAMP); \
	fi

vault-seed: vault-up
	$(VAULT_ENV_CMD) seed

vault-publish: vault-up
## Publish the current managed local env files into Vault without printing values.
	$(VAULT_ENV_CMD) publish

vault-status: vault-up
## Compare local and Vault managed env key coverage without printing secret values.
	$(VAULT_ENV_CMD) status

vault-policy-sync: vault-up
## Sync limited reader/writer policies for invited team secret access.
	$(VAULT_ENV_CMD) sync-policies
