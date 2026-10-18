# Vault session token targets and compatibility aliases — moved to apps/grobase.
vault-session-reader-token:
## Deprecated at root: reader invite tokens now mint from apps/grobase.
	@echo "[skip] vault-session-reader-token now lives in apps/grobase"

vault-session-writer-token:
## Deprecated at root: writer invite tokens now mint from apps/grobase.
	@echo "[skip] vault-session-writer-token now lives in apps/grobase"

get-secrets: vault-get-secrets
logout: vault-logout
