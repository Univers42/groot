# Shared Vault environment targets.
vault-fetch-shared:
## Fetch managed env files with VAULT_API_KEY, VAULT_TOKEN, or VAULT_TOKEN_FILE from an invited user.
	@set -eu; \
	token_file='$(VAULT_TOKEN_FILE)'; \
	token_source='none'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
		token_source="file:$$token_file"; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
		token_source='VAULT_API_KEY'; \
		echo '[vault] using VAULT_API_KEY from the current shell environment'; \
	elif [[ -n "$${VAULT_TOKEN:-}" ]]; then \
		token_source='VAULT_TOKEN'; \
		echo '[vault] using VAULT_TOKEN from the current shell environment'; \
	fi; \
	if [[ "$$token_source" == 'none' && -z "$${VAULT_TOKEN:-}" ]]; then \
		echo '[vault] missing shared Vault token'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] install $(VAULT_TOKEN_FILE) under this root or export VAULT_API_KEY/VAULT_TOKEN'; \
		exit 1; \
	fi; \
	: "$${VAULT_TOKEN:?Set VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	if [[ -z "$${VAULT_ADDR:-}" ]]; then \
		VAULT_ADDR='$(VAULT_SHARED_ADDR)'; \
		export VAULT_ADDR; \
		echo '[vault] no VAULT_ADDR supplied; defaulting shared Vault fetch to $(VAULT_SHARED_ADDR)'; \
	fi; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	vault_addr_is_local=0; \
	case "$$VAULT_ADDR" in \
		https://local-https-proxy:*|http://local-https-proxy:*) \
			VAULT_ADDR="$${VAULT_ADDR/local-https-proxy/localhost}"; \
			export VAULT_ADDR; \
			vault_addr_is_local=1; \
			echo '[vault] translated Docker-only Vault host local-https-proxy to localhost for host fetch'; \
			;; \
		https://localhost:*|http://localhost:*|https://127.0.0.1:*|http://127.0.0.1:*) \
			vault_addr_is_local=1; \
			;; \
	esac; \
	if [[ "$$vault_addr_is_local" == '1' ]]; then \
		if [[ '$(VAULT_ALLOW_LOCAL_SHARED)' == 'true' || '$(VAULT_ALLOW_LOCAL_SHARED)' == '1' ]]; then \
			echo '[vault] local shared fetch explicitly allowed; ensuring local Vault proxy is running'; \
			$(MAKE) vault-up; \
		else \
			echo '[vault] refusing localhost Vault address for shared env fetch.'; \
			echo '[vault] This token only works with the Vault instance on the machine that issued it.'; \
			echo '[vault] For a fresh VM or teammate machine, use a Fly-backed invite token:'; \
			echo '[vault]   maintainer: make vault-fly-invite-token VAULT_TEAM_ROLE=reader'; \
			echo '[vault]   teammate:   install .vault/track-binocle-reader.env, chmod 600 it, then make vault-shared-doctor'; \
			echo '[vault] If you have a bare Fly token, run: VAULT_API_KEY=... VAULT_ADDR=$(VAULT_SHARED_ADDR) make vault-fetch-shared'; \
			echo '[vault] For same-machine local token testing only, rerun with VAULT_ALLOW_LOCAL_SHARED=true.'; \
			exit 1; \
		fi; \
	fi; \
	if [[ -n '$(VAULT_NAMESPACE)' ]]; then export VAULT_NAMESPACE='$(VAULT_NAMESPACE)'; fi; \
	if [[ -z "$${NODE_EXTRA_CA_CERTS:-}" && -f '$(LOCAL_CA_CERT)' ]]; then export NODE_EXTRA_CA_CERTS='$(LOCAL_CA_CERT)'; fi; \
	$(NODE_RUN_SHARED) apps/baas/scripts/vault-env.mjs fetch

vault-shared-doctor:
## Check shared Vault token wiring without printing secret values.
	@set -eu; \
	token_file='$(VAULT_TOKEN_FILE)'; \
	token_source='none'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
		token_source="file:$$token_file"; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
		token_source='VAULT_API_KEY'; \
	elif [[ -n "$${VAULT_TOKEN:-}" ]]; then \
		token_source='VAULT_TOKEN'; \
	fi; \
	if [[ "$$token_source" == 'none' ]]; then \
		echo '[vault] no shared Vault token found'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] install $(VAULT_TOKEN_FILE) under this root or export VAULT_API_KEY/VAULT_TOKEN'; \
		exit 1; \
	fi; \
	if [[ -z "$${VAULT_ADDR:-}" ]]; then \
		VAULT_ADDR='$(VAULT_SHARED_ADDR)'; \
		export VAULT_ADDR; \
		echo '[vault] no VAULT_ADDR supplied; defaulting to $(VAULT_SHARED_ADDR)'; \
	fi; \
	echo "[vault] token source: $$token_source"; \
	echo "[vault] vault address: $$VAULT_ADDR"; \
	echo "[vault] env prefix: $${VAULT_ENV_PREFIX:-$(VAULT_ENV_PREFIX)}"; \
	case "$$VAULT_ADDR" in \
		https://local-https-proxy:*|http://local-https-proxy:*|https://localhost:*|http://localhost:*|https://127.0.0.1:*|http://127.0.0.1:*) \
			if [[ '$(VAULT_ALLOW_LOCAL_SHARED)' == 'true' || '$(VAULT_ALLOW_LOCAL_SHARED)' == '1' ]]; then \
				echo '[vault] localhost Vault allowed for same-machine testing'; \
			else \
				echo '[vault] problem: localhost Vault tokens are not portable to a fresh VM or teammate machine'; \
				echo '[vault] fix: replace this token with one generated by make vault-fly-invite-token'; \
				exit 1; \
			fi; \
			;; \
		*) \
			echo '[vault] shared Vault token wiring looks usable'; \
			;; \
	esac

env-fetch-shared:
## Fetch shared team secrets first when a reader/writer token is available.
	@set -eu; \
	if [[ -f '$(VAULT_TOKEN_FILE)' || -n "$${VAULT_API_KEY:-}" || -n "$${VAULT_TOKEN:-}" ]]; then \
		if $(MAKE) vault-fetch-shared VAULT_TOKEN_FILE='$(VAULT_TOKEN_FILE)'; then \
			echo '[vault] shared env fetch complete'; \
		elif [[ '$(VAULT_SHARED_REQUIRED)' == 'true' || '$(VAULT_SHARED_REQUIRED)' == '1' || "$${GITHUB_ACTIONS:-}" == 'true' ]]; then \
			exit 1; \
		else \
			echo '[vault] shared env fetch failed; continuing with local generated development secrets'; \
			echo '[vault] set VAULT_SHARED_REQUIRED=true to make shared Vault failures fatal'; \
		fi; \
	elif [[ "$${GITHUB_ACTIONS:-}" == 'true' ]]; then \
		echo '[vault] GitHub Actions must use its OIDC-generated Vault token file before make all.'; \
		exit 1; \
	elif [[ '$(VAULT_SHARED_REQUIRED)' == 'true' || '$(VAULT_SHARED_REQUIRED)' == '1' ]]; then \
		echo '[vault] missing shared Vault credentials. Set VAULT_API_KEY+VAULT_ADDR, VAULT_TOKEN+VAULT_ADDR, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE).'; \
		exit 1; \
	else \
		echo '[vault] missing shared Vault credentials; continuing with local generated development secrets'; \
		echo '[vault] current repository root: $(CURDIR)'; \
		echo '[vault] set VAULT_SHARED_REQUIRED=true to make this fatal'; \
	fi

vault-publish-shared:
## Publish managed env files with a writer VAULT_API_KEY, VAULT_TOKEN, or token file.
	@set -eu; \
	token_file='$(VAULT_PUBLISH_TOKEN_FILE)'; \
	if [[ -f "$$token_file" ]]; then \
		mode="$$(stat -c '%a' "$$token_file")"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $$token_file because it must be private; run: chmod 600 $$token_file"; exit 1;; esac; \
		set -a; . "$$token_file"; set +a; \
	elif [[ -f '$(VAULT_TOKEN_FILE)' ]]; then \
		mode="$$(stat -c '%a' '$(VAULT_TOKEN_FILE)')"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $(VAULT_TOKEN_FILE) because it must be private; run: chmod 600 $(VAULT_TOKEN_FILE)"; exit 1;; esac; \
		set -a; . '$(VAULT_TOKEN_FILE)'; set +a; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
	fi; \
	: "$${VAULT_TOKEN:?Set a writer VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_PUBLISH_TOKEN_FILE=$(VAULT_PUBLISH_TOKEN_FILE)}"; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE}"; \
	if [[ -n '$(VAULT_NAMESPACE)' ]]; then export VAULT_NAMESPACE='$(VAULT_NAMESPACE)'; fi; \
	$(NODE_RUN_SHARED) apps/baas/scripts/vault-env.mjs publish

vault-status-shared:
## Check managed Vault env coverage with an invited reader/writer API key or token.
	@set -eu; \
	if [[ -f '$(VAULT_TOKEN_FILE)' ]]; then \
		mode="$$(stat -c '%a' '$(VAULT_TOKEN_FILE)')"; \
		case "$$mode" in 400|600) ;; *) echo "[vault] refusing $(VAULT_TOKEN_FILE) because it must be private; run: chmod 600 $(VAULT_TOKEN_FILE)"; exit 1;; esac; \
		set -a; . '$(VAULT_TOKEN_FILE)'; set +a; \
	elif [[ -n "$${VAULT_API_KEY:-}" ]]; then \
		export VAULT_TOKEN="$$VAULT_API_KEY"; \
	fi; \
	: "$${VAULT_TOKEN:?Set VAULT_API_KEY, VAULT_TOKEN, or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	: "$${VAULT_ADDR:?Set VAULT_ADDR or provide VAULT_TOKEN_FILE=$(VAULT_TOKEN_FILE)}"; \
	if [[ -n '$(VAULT_NAMESPACE)' ]]; then export VAULT_NAMESPACE='$(VAULT_NAMESPACE)'; fi; \
	$(NODE_RUN_SHARED) apps/baas/scripts/vault-env.mjs status