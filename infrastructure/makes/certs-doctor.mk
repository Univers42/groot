# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    certs-doctor.mk                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:57:58 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:57:59 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Certificate diagnostics target.
certs-doctor: certs
## Check whether the local trust stores and running HTTPS proxy use the current local HTTPS CA.
	@bash apps/baas/scripts/trust-localhost-cert.sh --verify || true
	@if docker compose ps --status running --quiet local-https-proxy 2>/dev/null | grep -q .; then \
		port="$${OPPOSITE_OSIRIS_HOST_PORT:-4322}"; \
		tmp_cert="$$(mktemp)"; \
		if timeout 5 openssl s_client -connect "localhost:$$port" -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$$tmp_cert" 2>/dev/null \
			&& openssl verify -CAfile '$(LOCAL_CA_CERT)' "$$tmp_cert" >/dev/null 2>&1; then \
			echo "[certs] local HTTPS proxy serves the current Track Binocle CA on https://localhost:$$port"; \
		else \
			echo "[certs] local HTTPS proxy certificate on https://localhost:$$port does not verify against $(LOCAL_CA_CERT); recreate local-https-proxy with make up." >&2; \
			exit 1; \
		fi; \
		redirect_status="$$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$$port/" || true)"; \
		if [[ "$$redirect_status" =~ ^30(1|7|8)$$ ]]; then \
			echo "[certs] plain HTTP on localhost:$$port redirects to HTTPS"; \
		else \
			echo "[certs] expected plain HTTP on localhost:$$port to redirect to HTTPS, got HTTP $$redirect_status" >&2; \
			exit 1; \
		fi; \
		rm -f "$$tmp_cert"; \
	else \
		echo '[certs] local-https-proxy is not running; skipping live proxy certificate check'; \
	fi