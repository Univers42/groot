# HTTPS-Everywhere via a Local CA-Fronted TLS Reverse Proxy — platform / infrastructure (cross-cutting)

> Every frontend service exposed to the developer's browser is reachable exclusively over TLS 1.2/1.3, enforced by a single nginx reverse proxy whose certificate chains to a project-owned local CA that is imported into the system and NSS trust stores at stack-bring-up time.

## What it is (the concept)

**Transport Layer Security (TLS)** is a cryptographic protocol that authenticates the server and encrypts the channel between client and server, preventing third parties from reading or modifying in-flight data. In this stack the term **TLS termination** refers to the nginx `local-https-proxy` container that holds the private key and certificate; all upstream containers communicate over plain HTTP on Docker-internal networks and never touch the host network. The project generates its own **local Certificate Authority (CA)** (owned by the `apps/grobase` sub-stack) and issues a `localhost` leaf certificate from it; the CA is then **imported into the OS trust store and browser NSS databases** so browsers accept the certificate without a security warning.

## What it defends against

See [Man-in-the-Middle & Protocol Downgrade](../../attack/transport-security-tls.md). In this application's context, all authentication tokens, session cookies, workspace content, and BaaS API keys transit between the browser and the service layer; without TLS any process with packet visibility on the same machine (or hypervisor host) could read or replace those values. Restricting the negotiated protocol to TLS 1.2/1.3 also eliminates the family of **protocol-downgrade attacks** (POODLE, BEAST, DROWN) that exploit known weaknesses in SSL 3.0, TLS 1.0, and TLS 1.1.

## How the platform implements it

**Nginx TLS termination with protocol pinning**

[`infrastructure/tls/nginx.conf`](../../../../infrastructure/tls/nginx.conf) is the single nginx configuration loaded by the proxy. Line 12 sets the global protocol floor:

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
```

Every one of the 11 `server {}` blocks repeats the directive locally (e.g. lines 48, 78, 88, 98, …) so there is no inherited-default ambiguity. Each block loads the same leaf certificate pair:

```nginx
ssl_certificate     /etc/track-binocle/certs/localhost.pem;
ssl_certificate_key /etc/track-binocle/certs/localhost-key.pem;
```

**HTTP-to-HTTPS 308 redirect**

Line 22 of the same file uses nginx's `error_page 497` hook (triggered when a plain HTTP client connects to an `ssl`-only listener) to issue a permanent redirect:

```nginx
error_page 497 =308 https://$host:$server_port$request_uri;
```

No plain-HTTP listener exists; port 497 is the nginx mechanism that fires before the connection is accepted, making HTTP downgrade impossible by construction.

**HSTS header for the website**

The `:4322` server block (opposite-osiris) also emits a **HTTP Strict-Transport-Security** header (line 55):

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

This instructs browsers to reject future plain-HTTP connections to the same origin for one year, even if nginx were somehow bypassed.

**Local CA generation and system-store trust**

[`infrastructure/makes/certs.mk`](../../../../infrastructure/makes/certs.mk) delegates CA and leaf certificate generation to `apps/grobase` (`$(MAKE) -C apps/grobase certs`) and then defines the `TRUST_LOCAL_CA` macro (lines 23–51). When invoked, it copies `apps/grobase/certs/…-ca.crt` to `/usr/local/share/ca-certificates/track-binocle-local-ca.crt` and calls `sudo update-ca-certificates`, then iterates over every discovered NSS database (Chromium `~/.pki/nssdb`, Firefox profiles including Snap and Flatpak variants) and runs:

```bash
certutil -A -n 'Track Binocle Local CA' -t 'C,,' -i "$src" -d "sql:$db"
```

**Compose service wiring**

[`docker-compose.yml`](../../../../docker-compose.yml) lines 4–25 define the `local-https-proxy` service. The nginx configuration and the certificate directory are both mounted read-only:

```yaml
volumes:
  - ./infrastructure/tls/nginx.conf:/etc/nginx/nginx.conf:ro
  - ./apps/grobase/certs:/etc/track-binocle/certs:ro
```

All TLS ports bind to `${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}` by default (loopback-only), so services are never reachable on the host's external interface unless the operator explicitly overrides the variable (auto-set to `0.0.0.0` in VirtualBox mode).

## How we know it is applied

**Compose healthcheck** — the `local-https-proxy` service declares:

```yaml
healthcheck:
  test: ["CMD-SHELL", "nginx -t >/dev/null 2>&1"]
```

Docker will not mark the container healthy, and dependent services will not start, if nginx fails to parse the TLS configuration.

**Live runtime probe via `certs-doctor`** — [`infrastructure/makes/certs-doctor.mk`](../../../../infrastructure/makes/certs-doctor.mk) lines 28–41 actively verify the running proxy:

```bash
timeout 5 openssl s_client -connect "localhost:$port" -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -out "$tmp_cert" 2>/dev/null \
  && openssl verify -CAfile '$(LOCAL_CA_CERT)' "$tmp_cert" >/dev/null 2>&1
```

If the served certificate does not chain to the project CA the target exits 1. A second check (lines 35–41) confirms the plain-HTTP redirect is active:

```bash
redirect_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$port/" || true)"
[[ "$redirect_status" =~ ^30(1|7|8)$ ]] || exit 1
```

**`make all` wiring** — the root `Makefile` recipe includes `certs` and `certs-trust-local` as mandatory prereqs before `frontends-up`, so the CA is generated and trusted on every cold-start before any service is exposed to the browser.

## Reference

The [Transport Layer Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html) (OWASP) defines the minimum acceptable configuration: TLS 1.2 as the floor, strong cipher suites, HSTS with a `max-age` of at least one year, and certificate validity chains. This implementation satisfies those baselines — TLSv1.2/1.3 only, `ssl_prefer_server_ciphers off` (delegating cipher selection to the client, which is the modern recommendation), and a one-year HSTS policy on the primary frontend origin.

## Residual risk / assumptions

- **CA private key is on disk.** The `apps/grobase/certs/` directory contains the CA private key as a plain file inside the repo working tree. Anyone with read access to the developer's filesystem can impersonate any service. This is an accepted trade-off for a local-dev CA; production deployments must use a proper PKI.
- **Loopback scope only.** The `127.0.0.1` default binding means TLS is only enforced on the local machine. Connections between containers (nginx → upstream services) are plain HTTP on Docker bridge networks, relying entirely on Docker network isolation.
- **No OCSP / CRL.** The local CA does not operate a revocation endpoint. Certificate compromise requires manual `make certs` rotation.
- **VirtualBox bind override.** When `TRACK_BINOCLE_BIND_ADDR=0.0.0.0` is set (hypervisor mode), TLS-protected ports are reachable from the host machine's network, extending the attack surface beyond loopback.
- **Kong BaaS gateway is HTTP-only internally.** Connections to `http://127.0.0.1:8000` (Kong plain) bypass the nginx proxy entirely; only `https://localhost:8000` (via the proxy's `:8000` server block) is TLS-protected.
