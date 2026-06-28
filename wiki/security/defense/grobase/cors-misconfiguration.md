# CORS Misconfiguration Defense — grobase (the BaaS backend)

> Kong enforces a closed, enumerated origin allowlist with no wildcard, ensuring that
> cross-origin requests carrying credentials can only originate from the four configured
> application domains.

## What it is (the concept)

**Cross-Origin Resource Sharing (CORS)** is a browser security mechanism that lets a
server declare which external origins may read its responses. A **preflight request**
(HTTP OPTIONS) is issued by the browser before any credentialed or non-simple request;
the server replies with `Access-Control-Allow-Origin` and related headers, and the browser
enforces the policy before exposing the response to the calling script. The critical
invariant is that `Access-Control-Allow-Origin: *` and `Access-Control-Allow-Credentials: true`
must never coexist: **a wildcard origin with credentials** would allow any site on the web
to read authenticated responses.

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md).

In this stack, a misconfigured CORS policy would allow a malicious third-party site to
issue credentialed requests to the Kong gateway (`http://127.0.0.1:8000`) and read the
authenticated JSON response — including workspace data, storage signed URLs, and GoTrue
session payloads. Because the browser sends cookies and the `Authorization` header
automatically in credentialed requests, an overly permissive allowlist directly enables
cross-origin credential theft against any logged-in user of osionos or opposite-osiris.

## How grobase implements it

The control is a **global Kong CORS plugin** declared in
[`apps/grobase/infra/docker/services/kong/conf/kong.yml`](../../../../apps/grobase/infra/docker/services/kong/conf/kong.yml)
(lines 33–55). Being a top-level `plugins:` entry in Kong's declarative config, it applies
to every route in the gateway without per-route repetition:

```yaml
- name: cors
  config:
    origins:
      - __KONG_CORS_ORIGIN_APP__
      - __KONG_CORS_ORIGIN_PLAYGROUND__
      - __KONG_CORS_ORIGIN_STUDIO__
      - __KONG_CORS_ORIGIN_FRONTEND__
      - http://localhost:3001
      - http://127.0.0.1:3001
    methods: [GET, POST, PUT, PATCH, DELETE, OPTIONS]
    headers:
      [Authorization, Content-Type, Content-Profile, apikey, X-Baas-Api-Key,
       X-Baas-Tenant-Id, x-client-info, X-Request-ID, Prefer, Range, Accept,
       Accept-Profile, x-supabase-api-version]
    exposed_headers:
      [X-Kong-Upstream-Latency, X-Kong-Proxy-Latency, X-Request-ID]
    credentials: true
    max_age: 3600
```

The four `__KONG_CORS_ORIGIN_*__` placeholders are resolved at container boot, not at
build time. The four `KONG_CORS_ORIGIN_*` variables are set to explicit `https://` hosts
in
[`apps/grobase/.env`](../../../../apps/grobase/.env):

```
KONG_CORS_ORIGIN_APP=https://localhost:3000
KONG_CORS_ORIGIN_PLAYGROUND=https://localhost:3100
KONG_CORS_ORIGIN_STUDIO=https://localhost:3001
KONG_CORS_ORIGIN_FRONTEND=https://localhost:4322
```

No value is `*`. The `exposed_headers` list is also closed: only Kong latency counters
and the correlation ID are surfaced, so response headers carrying internal routing
information are never readable by a cross-origin script.

## How we know it is applied

The gateway compose plane in
[`apps/grobase/orchestrators/compose/base/gateway.yml`](../../../../apps/grobase/orchestrators/compose/base/gateway.yml)
overrides the Kong container's startup `command` with an inline `sed` pipeline that
substitutes every `__KONG_CORS_ORIGIN_*__` placeholder from the environment before Kong
reads the config (lines 65–78):

```yaml
command: >
  sh -ec '
    sed \
      -e "s|__KONG_CORS_ORIGIN_APP__|$${KONG_CORS_ORIGIN_APP}|g" \
      -e "s|__KONG_CORS_ORIGIN_PLAYGROUND__|$${KONG_CORS_ORIGIN_PLAYGROUND}|g" \
      -e "s|__KONG_CORS_ORIGIN_STUDIO__|$${KONG_CORS_ORIGIN_STUDIO}|g" \
      -e "s|__KONG_CORS_ORIGIN_FRONTEND__|$${KONG_CORS_ORIGIN_FRONTEND}|g" \
      /etc/kong/kong.yml.tmpl > /tmp/kong.yml;
    exec /docker-entrypoint.sh kong docker-start
  '
```

`KONG_DECLARATIVE_CONFIG` is set to `/tmp/kong.yml` (the substituted output), so Kong
starts with the rendered config containing no remaining placeholders. The `env_file: [.env]`
directive on the same service block injects the four `KONG_CORS_ORIGIN_*` variables from
the verified `.env` file.

The verify gate
[`apps/grobase/scripts/verify/m84-console-route.sh`](../../../../apps/grobase/scripts/verify/m84-console-route.sh)
exercises a byte-faithful reproduction of the Kong declarative config against a live
tenant-control container, including the global `cors` block with `credentials: true` and
the same `max_age: 3600` shape — confirming the config structure that production uses
holds under live exercising.

Additionally,
[`apps/grobase/scripts/vault/vault-env.mjs`](../../../../apps/grobase/scripts/vault/vault-env.mjs)
lists all four `KONG_CORS_ORIGIN_*` vars in its `recommended` audit set and seeds them
with explicit `https://localhost:<port>` defaults (lines 246–249), ensuring no deployment
path can inadvertently leave them blank or set to `*`.

## Reference

The [HTML5 Security Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)
addresses CORS as part of the browser security surface, detailing the exact interaction
between `Access-Control-Allow-Origin`, `Access-Control-Allow-Credentials`, and preflight
mechanics that grobase's allowlist design guards against. The design choice to enumerate
exact origins rather than rely on a prefix or subdomain pattern is consistent with the
cheat sheet's principle that origin validation must be exact and not rely on string
matching that could be circumvented — this maps to OWASP A05:2021 Security Misconfiguration.

## Residual risk / assumptions

- **HTTP dev origins are hardcoded.** The two `http://localhost:3001` and
  `http://127.0.0.1:3001` entries in the template are not driven by environment variables;
  they are always present. In a production deployment where the osionos dev server is not
  running, these origins add no real attack surface (no browser would be on those origins),
  but they cannot be disabled without editing the template.
- **No wildcard-check CI gate.** There is no automated step that fails the build if a
  `KONG_CORS_ORIGIN_*` variable is set to `*`. A misconfigured `.env` would silently
  produce a wildcard allowlist; the control relies on operator discipline and vault42
  secret management, not an enforced constraint.
- **Kong Admin API is not published to the host.** The `KONG_ADMIN_LISTEN: 0.0.0.0:8001`
  binding is intentional for internal Prometheus scraping, but the CORS policy does not
  govern the Admin API — it is unprotected by CORS (no browser origin check). The existing
  defense (Admin API port not published to any host interface) is documented in
  `apps/grobase/orchestrators/compose/base/gateway.yml` (line 41–45) and is orthogonal to
  the CORS plugin.
- **WebSocket connections** to `/realtime/v1/ws` are not subject to CORS preflight — the
  browser enforces the `Origin` header check at the WebSocket handshake level, but Kong
  does not apply the CORS plugin to WebSocket upgrades. Realtime authentication is handled
  in-band within the WebSocket protocol.
