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
# localhost cert under apps/grobase/certs). Trust is a small inline import of the
# grobase CA into the system store (+ NSS via certutil when available), guarded so
# it no-ops gracefully when sudo/certutil are missing.
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
	if command -v certutil >/dev/null 2>&1; then \
		for db in "$$HOME/.pki/nssdb" $$HOME/.mozilla/firefox/*.default* $$HOME/snap/firefox/common/.mozilla/firefox/*.default* $$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/*.default*; do \
			[[ -d "$$db" ]] || continue; \
			certutil -D -n 'Track Binocle Local CA' -d "sql:$$db" >/dev/null 2>&1 || true; \
			certutil -A -n 'Track Binocle Local CA' -t 'C,,' -i "$$src" -d "sql:$$db" >/dev/null 2>&1 \
				&& echo "[certs] grobase CA imported into NSS db $$db" || true; \
		done; \
	fi
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

certs-trust-local: certs
## Trust the grobase CA for developer browsers and system-trust clients; skipped in CI.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser trust import in CI/noninteractive mode'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'skip' ]]; then \
		echo '[certs] skipping local CA trust import because TRACK_BINOCLE_CERT_TRUST=skip'; \
	else \
		$(TRUST_LOCAL_CA); \
	fi