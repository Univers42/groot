# Vault session authentication targets — Vault tooling moved to the standalone apps/grobase stack.
vault-session-node-check:
## Check that host Node.js is available for Vault session commands.
	@command -v node >/dev/null 2>&1 || { echo '[vault-session] host Node.js is required for Vault session targets.'; exit 1; }

vault-session-check:
## Deprecated at root: Vault session check now lives in apps/grobase.
	@echo "[skip] vault-session-check now lives in apps/grobase"

vault-login-user:
## Deprecated at root: Vault user login now lives in apps/grobase.
	@echo "[skip] vault-login-user now lives in apps/grobase"

vault-login-approle:
## Deprecated at root: Vault AppRole login now lives in apps/grobase.
	@echo "[skip] vault-login-approle now lives in apps/grobase"

vault-login-jwt:
## Deprecated at root: Vault JWT login now lives in apps/grobase.
	@echo "[skip] vault-login-jwt now lives in apps/grobase"
