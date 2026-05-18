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
certs:
## Generate the local HTTPS CA and localhost certificate used by the Docker TLS proxy.
	bash apps/baas/scripts/generate-localhost-cert.sh

certs-trust: certs
## Trust the local HTTPS CA in user browser stores; use EXTRA_ARGS=--system for the Linux system store.
	bash apps/baas/scripts/trust-localhost-cert.sh $(EXTRA_ARGS)

certs-trust-system: certs
## Trust the local HTTPS CA in the Linux system store for VS Code/Electron and system-trust browsers.
	bash apps/baas/scripts/trust-localhost-cert.sh --system

certs-trust-browser-host: certs
## Copy and trust the local HTTPS CA on the forwarded browser host over SSH/SCP when reachable.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser-host trust import in CI/noninteractive mode'; \
	else \
		bash apps/baas/scripts/trust-browser-host-ca.sh; \
	fi

certs-trust-local: certs
## Trust the local HTTPS CA for developer browsers and system-trust clients; skipped in CI.
	@if [[ "$${CI:-}" == 'true' || "$${GITHUB_ACTIONS:-}" == 'true' || "$${TRACK_BINOCLE_SKIP_CERT_TRUST:-}" == '1' ]]; then \
		echo '[certs] skipping browser trust import in CI/noninteractive mode'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'skip' ]]; then \
		echo '[certs] skipping local CA trust import because TRACK_BINOCLE_CERT_TRUST=skip'; \
	elif [[ "$${TRACK_BINOCLE_CERT_TRUST:-$(CERT_TRUST_MODE)}" == 'browser' ]]; then \
		bash apps/baas/scripts/trust-localhost-cert.sh; \
	elif [[ -t 0 || -t 1 ]] || { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }; then \
		bash apps/baas/scripts/trust-localhost-cert.sh --system; \
	else \
		echo '[certs] cannot update the system CA store without an interactive terminal or cached sudo.' >&2; \
		echo '[certs] Rerun make all from a terminal, run make certs-trust-system, or set TRACK_BINOCLE_CERT_TRUST=browser/skip intentionally.' >&2; \
		exit 1; \
	fi