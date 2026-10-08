# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    certs.mk                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:58:01 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:58:02 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Certificate generation and trust targets.
# Generation is delegated to the standalone apps/grobase stack (it owns the CA +
# localhost cert under apps/grobase/certs). Trust has two halves: the system store
# (one sudo, inline below, for curl/Electron/system-trust clients) and this user's
# browser stores (scripts/certs-trust-user.sh: Chrome's NSS db and every Firefox
# profile, no sudo). Both no-op with a message when sudo/certutil are missing.
certs:
## Generate the local HTTPS CA and localhost certificate (delegated to apps/grobase).
	$(MAKE) -C apps/grobase certs

# Inline trust of the grobase CA: system store + NSS (certutil) when present.
define TRUST_LOCAL_CA
	src='$(CURDIR)/$(LOCAL_CA_CERT)'; \
	if [[ ! -f "$$src" ]]; then echo "[certs] no CA at $$src; run make certs first" >&2; exit 0; fi; \
	dst='/usr/local/share/ca-certificates/track-binocle-local-ca.crt'; \
	if [[ -f "$$dst" ]] && cmp -s "$$src" "$$dst"; then \
		echo '[certs] grobase CA already trusted in the system store'; \
	elif command -v sudo >/dev/null 2>&1 && command -v update-ca-certificates >/dev/null 2>&1; then \
		if [[ -t 0 && "$${CI:-}" != 'true' && "$${GITHUB_ACTIONS:-}" != 'true' ]]; then \
			echo '[certs] trusting the grobase CA in the system store (one sudo prompt)…'; \
			sudo cp "$$src" "$$dst" && sudo update-ca-certificates >/dev/null 2>&1 \
				&& echo '[certs] grobase CA trusted in the system store' \
				|| echo '[certs] system CA trust FAILED — re-run once: sudo make certs-trust-local'; \
		else \
			sudo -n cp "$$src" "$$dst" 2>/dev/null && sudo -n update-ca-certificates >/dev/null 2>&1 \
				&& echo '[certs] grobase CA trusted (passwordless sudo)' \
				|| echo '[certs] system CA trust skipped (non-interactive) — run once: sudo make certs-trust-local'; \
		fi; \
	else \
		echo '[certs] update-ca-certificates/sudo not available; skipping system CA trust'; \
	fi; \
	bash scripts/certs-trust-user.sh "$$src" \
		|| echo '[certs] a browser store import FAILED (above); re-run: make certs-trust-user'
endef

certs-trust: certs
## Trust the grobase CA in the system + NSS stores.
	@$(TRUST_LOCAL_CA)

certs-trust-system: certs
## Trust the grobase CA in the Linux system store for VS Code/Electron and system-trust browsers.
	@$(TRUST_LOCAL_CA)

certs-trust-browser-host: certs
## No-op at root: forwarded-browser-host trust moved with the backend to apps/grobase.
	@echo '[skip] certs-trust-browser-host now lives in apps/grobase'

# `certs` only when the CA is missing: with one present nothing in apps/grobase is touched,
# so this works where that target does not (an NFS tree refuses the WAF gid, runbook).
certs-trust-user:
## Trust the local CA in THIS user's browser stores, no sudo: Chrome/Chromium's NSS db and every Firefox profile (deb, snap, flatpak), replacing any copy from an older tree. A running browser sees it after a relaunch. Mints the CA first when there is none.
	@[ -f '$(LOCAL_CA_CERT)' ] || $(MAKE) --no-print-directory certs
	@bash scripts/certs-trust-user.sh '$(LOCAL_CA_CERT)'

certs-trust-check:
## One line per browser store: does it hold the CURRENT local CA (ok|FAIL kind path state); exit 1 when one is stale or missing.
	@bash scripts/certs-trust-user.sh --check '$(LOCAL_CA_CERT)'

certs-trust-local: certs
## Trust the grobase CA for developer browsers and system-trust clients; skipped in CI. CERT_TRUST_MODE / TRACK_BINOCLE_CERT_TRUST = system (default, one sudo + browsers) | user (browsers only, no sudo) | skip.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser trust import in CI/noninteractive mode'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'skip' ]]; then \
		echo '[certs] skipping local CA trust import because TRACK_BINOCLE_CERT_TRUST=skip'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'user' ]]; then \
		bash scripts/certs-trust-user.sh '$(LOCAL_CA_CERT)'; \
	else \
		$(TRUST_LOCAL_CA); \
	fi

certs-export:
## Copy the local CA to DEST (default ./track-binocle-local-ca.pem) for a browser on another machine; prints its SHA-256 fingerprint and the host import commands. No sudo.
	@bash scripts/certs-export.sh '$(LOCAL_CA_CERT)' '$(or $(DEST),track-binocle-local-ca.pem)'
