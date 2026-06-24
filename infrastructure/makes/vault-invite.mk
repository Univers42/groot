# Vault invite token targets.
vault-invite-token:
## Deprecated at root: Vault invite tokens now mint from apps/grobase.
	@echo "[skip] vault-invite-token now lives in apps/grobase"

vault-fly-invite-token:
## Create an ignored .vault invite token file from the Fly-hosted Vault.
	@if [[ -z '$(FLY_BIN)' && -z "$${FLY_API_TOKEN:-}" ]]; then \
		echo '[vault] flyctl not found locally and FLY_API_TOKEN is not set.'; \
		echo '[vault] Either install flyctl (curl -L https://fly.io/install.sh | sh) or export FLY_API_TOKEN=<token>.'; \
		echo '[vault] With FLY_API_TOKEN set the containerised flyctl in vault-fly will be used automatically.'; \
		exit 1; \
	fi
	@mkdir -p .vault
	@set -eu; token_file='.vault/fly-vault-root-token'; trap 'rm -f "$$token_file"' EXIT; \
		$(FLY) ssh console --app $(FLY_VAULT_APP) --command 'jq -r .root_token /vault/data/.vault-keys.json' > "$$token_file"; \
		chmod 600 "$$token_file"; \
		token="$$(tr -d '\r\n' < "$$token_file")"; \
		echo '[skip] vault-fly-invite-token now lives in apps/grobase'

vault-reader-token:
## Create an ignored reader invite token from the Fly-hosted shared Vault.
	$(MAKE) vault-fly-invite-token VAULT_TEAM_ROLE=reader VAULT_TEAM_TOKEN_FILE='$(VAULT_READER_TOKEN_FILE)'

vault-writer-token:
## Create an ignored writer invite token from the Fly-hosted shared Vault.
	$(MAKE) vault-fly-invite-token VAULT_TEAM_ROLE=writer VAULT_TEAM_TOKEN_FILE='$(VAULT_WRITER_TOKEN_FILE)'