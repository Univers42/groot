# Security Misconfiguration Controls — grobase (the BaaS backend)

> grobase actively refuses to boot on any known-weak or missing internal credential, keeps its
> administrative API plane off the host network, and scopes WAF rule relaxations surgically so
> the engine stays blocking on all paths that are not explicitly carved out.

---

## What it is (the concept)

**Security misconfiguration** occurs when a system ships with insecure defaults, leaves unnecessary
surfaces exposed, or relaxes security controls more broadly than needed to work around false
positives. The OWASP category encompasses shipped default credentials, over-permissive ports,
globally disabled middleware, and incomplete production hardening. In practice the most dangerous
variant is a **fail-open default**: a service that starts successfully even when its secrets are
empty or publicly known placeholders, silently trusting anyone who knows the default token.

---

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

In the grobase context, the concrete threats are:

- **Default-credential exploitation**: an attacker who knows the Docker-compose default
  `INTERNAL_SERVICE_TOKEN` (`dev-service-token-change-me`) could forge control-plane authentication
  and provision or destroy tenants without a real secret.
- **Admin API key extraction**: Kong in db-less mode exposes its full declarative config (including
  the cleartext `anon` and `service_role` keys and the JWT signing secret) over its Admin API; if
  that port were published to the host, any host-local process or host-bound SSRF could dump every
  key with a single GET request.
- **WAF self-disable creep**: operators who see legitimate PostgREST filter syntax or JWT Bearer
  tokens trip SQLi rules often respond by setting `SecRuleEngine DetectionOnly` globally — turning
  the whole WAF into a passive observer and eliminating its blocking effect for every path.

---

## How grobase implements it

### 1. Fail-closed startup on weak or missing internal service token

`apps/grobase/src/control-plane/internal/config/config.go` implements `LoadConfig()`, the shared
entrypoint for every Go control-plane binary. It explicitly defines the well-known placeholder and
rejects it at startup:

```go
// config.go lines 22–26, 69–74
const weakServiceToken = "dev-service-token-change-me"

if cfg.ServiceToken == "" || cfg.ServiceToken == weakServiceToken {
    return Config{}, fmt.Errorf(
        "INTERNAL_SERVICE_TOKEN must be set to a strong value "+
            "(refusing empty or the placeholder %q); ...", weakServiceToken)
}
```

A `LoadConfig` error propagates to each binary's `main()` as an `os.Exit(1)` — the service simply
does not start. The error message names both the problem and the recovery path
(`JWT_SECRET` or `ADAPTER_REGISTRY_SERVICE_TOKEN`).

At `SECURITY_MODE=max` the enforcement goes further:
`apps/grobase/src/control-plane/internal/config/vaultcreds.go` contains
`requireVaultBackedCredentials()`, which is called unconditionally at the end of `LoadConfig`. At the
`max` posture it verifies that `VAULT_ADDR` is present, that the master credential value is not a
known placeholder, and that it meets a minimum length — returning an error on any failure. The error
message explicitly states "no silent fallback to a weak credential", preventing silent degradation to
an insecure default when Vault is unreachable.

### 2. Kong Admin API kept off the host network

`apps/grobase/orchestrators/compose/base/gateway.yml` publishes only the Kong proxy port to the host
and documents the security rationale inline:

```yaml
# gateway.yml lines 39–45
# Keep 8000 exposed on localhost for direct dev access.
- "127.0.0.1:${KONG_HTTP_PORT:-8000}:8000"
# SECURITY: the Admin API (:8001) is NOT published to the host — in db-less
# mode `GET /key-auths` returns the cleartext anon + service_role keys (and
# /jwts the JWT secret). It stays on 0.0.0.0:8001 inside the container so
# Prometheus can scrape `kong:8001` over the internal network, but no host
# process (or host-bound SSRF) can reach it.
```

Port 8001 has no host binding at all; it exists on the Docker-internal network only so Prometheus
can scrape Kong's metrics. `KONG_ADMIN_LISTEN` is kept at `0.0.0.0:8001` (container-local) rather
than being disabled, because the Prometheus scraper target is `kong:8001` over the `mini-baas`
bridge network.

### 3. WAF rule tuning — scoped relaxations, engine stays blocking

`apps/grobase/infra/docker/services/waf/conf/modsecurity.conf` sets `SecRuleEngine On` globally
(blocking mode) and then carves out the minimum set of per-rule, per-path relaxations needed to
avoid false positives on BaaS-specific traffic:

- **`id:300001`** — turns the rule engine `Off` for the exact path `^/waf-health$` only (liveness
  probe; no payload to inspect).
- **`id:300002`** — forces `requestBodyProcessor=JSON` on `/rest/`, `/mongo/`, `/query/`,
  `/admin/`, `/email/`, `/schemas/`, `/permissions/` API paths so the correct body parser is always
  used.
- **`id:300010`** — removes ten specific SQLi `ARGS` rules (942100, 942120, 942130, 942150, 942180,
  942200, 942260, 942340, 942370, 942432) scoped to `^/rest/v1/` only, because PostgREST
  filter-grammar tokens like `?column=eq.value` and `ilike.*` trigger generic SQLi pattern matching.
  All other rules — and all other paths — remain fully active.
- **`id:300020`** — removes three SQLi header rules (942100, 942440, 942450) on
  `REQUEST_HEADERS:authorization` for `^/auth/v1/` only, because JWT Bearer tokens encoded in
  Base64url trigger base64-injection pattern matching.
- **`id:300030`** — removes rule 920420 (disallowed content-type) on `^/storage/v1/` for file
  upload paths.

The engine is never switched to `DetectionOnly` globally. Every relaxation names both the rule ID
and the exact path scope, making the residual attack surface explicit.

### 4. Production overlay removes direct data-store ports

`apps/grobase/orchestrators/compose/docker-compose.prod.yml` is an additive overlay (applied with
`-f docker-compose.prod.yml`) that sets `ports: []` on every data store and internal service:
Postgres, MongoDB, Redis, MySQL, MariaDB, CockroachDB, MSSQL, the Iceberg REST catalog, GoTrue,
PostgREST, and the Studio. Its header states the design rationale:

```
# no direct dev ports... the gateway is the single public door
```

Kong (the product gateway) and Grafana (operator dashboard, with an explicit firewall note) are the
only services that intentionally retain published ports in production.

---

## How we know it is applied

**Boot-refuse gate (CI-pinned unit test):**
`apps/grobase/src/control-plane/internal/config/config_test.go` contains
`TestLoadConfigRejectsWeakServiceToken`, which asserts:

```go
{"placeholder rejected", weakServiceToken, true},   // must error
{"max + compose placeholder rejected", "max", "...", "http://vault:8200", "", true},
{"baseline ignores placeholder key (parity)", "baseline", "...", "", "", false},
```

This test runs in `go test ./...` (the `make go-control-plane-check` target) on every CI pass. A
regression — any code path that allows a weak token through — is caught before merge.

**Kong Admin API gate (live runtime assertion):**
`apps/grobase/scripts/verify/m157-kong-admin-not-exposed.sh` is the milestone gate for this control.
It asserts three things against the live `mini-baas-kong` container:

```bash
# m157 lines 28–30
ADMIN_PUB="$(docker port mini-baas-kong 8001/tcp 2>/dev/null || true)"
[ -z "$ADMIN_PUB" ] || fail "Kong Admin API is published to the host ($ADMIN_PUB) — keys are dumpable via /key-auths"
ok "admin API :8001 is not published to the host"
```

It also confirms the proxy on `:8000` still serves (the fix is not an over-correction that breaks
the API) and that `docker compose config` no longer shows an 8001 host binding.

**WAF:** the exclusion rules are baked into the WAF image at build time
(`Dockerfile COPY conf/modsecurity.conf /etc/modsecurity.d/modsecurity-override.conf`). The m140
gate (network-controls + WAF band) observes 403 responses on generic attack paths, confirming the
engine is blocking and the exclusions are path-scoped.

---

## Reference

[A05 Security Misconfiguration — OWASP Top 10:2021](https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/)

OWASP places Security Misconfiguration at A05:2021, noting that 90% of applications tested positive
for some form of it, with an incidence rate of 4.51%. The category explicitly covers default
credentials, unnecessarily enabled features, overly permissive cloud storage, missing hardening
across the stack, and unnecessary features left enabled — exactly the surface grobase hardens through
the controls above.

---

## Residual risk and assumptions

- **WAF ARGS relaxation on `/rest/v1`**: the ten removed SQLi rules no longer protect against
  SQL-injection payloads delivered through PostgREST `ARGS`. Residual protection relies on
  PostgREST's parameterized query generation and Postgres type casting — not on the WAF. A
  PostgREST bug that passes raw SQL through would not be caught by ModSecurity on that path.
- **`SECURITY_MODE=max` is opt-in**: the Vault-backed fail-closed enforcement only activates when
  `SECURITY_MODE=max` is explicitly set. The default `baseline` mode still rejects empty and
  placeholder tokens (the `weakServiceToken` check runs unconditionally) but does not require
  Vault provenance of credentials. Operators who do not set `SECURITY_MODE=max` in production
  accept a weaker posture.
- **Production overlay is opt-in**: `docker-compose.prod.yml` is an additive overlay; the default
  `make all` stack (the `migrate` edition) does not apply it. The base stack publishes Kong on
  `127.0.0.1:8000` but also publishes loopback ports for some data stores in dev configurations.
  The overlay must be explicitly included in production deployments.
- **Kong Admin API on container loopback**: port 8001 is bound to `0.0.0.0` inside the container for
  Prometheus. A container escape or a misconfigured network policy that joins an attacker container
  to the `mini-baas` bridge network would expose the Admin API. The control depends on Docker
  network isolation remaining intact.
- **No automated WAF regression test**: there is no CI gate that replays a post-exclusion SQLi
  payload against `/rest/v1` and asserts it is still rejected at the application layer (PostgREST).
  Manual verification or a dedicated Nuclei/sqlmap gate (`make baas-security-audit`) covers this gap
  only when run explicitly.
