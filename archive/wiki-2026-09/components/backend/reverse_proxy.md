# Kong — the reverse proxy (the single front door)

> **In one sentence.** Kong is the public HTTPS [reverse proxy](glossary.md#reverse-proxy) that sits at the single entry point, authenticates every request via [API key](glossary.md#api-key) or signed [JWT](glossary.md#jwt-json-web-token), decodes identity claims from the JWT and forwards them as trusted headers while stripping client-supplied identity headers to prevent forgery, then routes by [path prefix](glossary.md#path-prefix-routing) to the appropriate backend service.

## What it is & why it exists

Kong is the gateway—the first and only public-facing component that touches every request. It runs in declarative ([database-less](glossary.md#db-less-mode)) mode, consuming a static YAML configuration that defines all routes, services, plugins, and authentication consumers. The gateway is production-simple: container, env vars, one [Lua](glossary.md#lua-pre-function--lua-sandbox) pre-function hook, no mutable state.

Why it exists: because every backend service needs consistent, trustworthy authentication and the same cross-cutting security ([CORS](glossary.md#cors-cross-origin-resource-sharing), [rate-limits](glossary.md#rate-limiting), hardened response headers). Rather than scatter auth logic across 20+ upstreams, Kong centralizes it. Every upstream receives requests as already-authenticated (X-User-Id header set only if a valid JWT was verified) and never receives a client-forged identity header ([header forgery](glossary.md#header-forgery--header-injection) is defeated because Kong strips them all upfront).

## How it works

- Every request arrives at Kong on port 8000 (or behind WAF on 8443).
- Kong's global plugins run in order: CORS preflight is handled, a [correlation ID](glossary.md#correlation-id) is assigned, [Prometheus metrics](glossary.md#prometheus-metrics) are incremented.
- The pre-function (Lua) plugin runs in the access phase: it unconditionally clears any X-User-*, X-Baas-Tenant-*, X-Tenant-Id headers the client supplied (the defense).
- Kong extracts the Authorization header and looks for a Bearer token.
- If a Bearer token is present, the pre-function [base64url](glossary.md#base64url-encoding)-decodes its payload (the middle segment between dots), parses it as JSON, and extracts the claims (sub = user ID, email, role).
- The pre-function sets those claims as trusted headers (X-User-Id, X-User-Email, X-User-Role) that upstreams will receive.
- Kong's jwt plugin validates the token signature using the configured JWT secret (HS256); if it fails, the request is rejected (401).
- Kong matches the request path against the route table (longest prefix first) and dispatches to the mapped upstream (PostgREST, query-router, data plane, etc.).
- If a route requires key-auth, Kong validates the apikey header against the registered consumer keys; if absent or invalid, the request is rejected (401).
- Per-route rate-limiting checks the request count for this IP address; if over the limit, the request is rejected (429).
- The request is forwarded to the upstream with all headers intact (including the trusted X-User-* headers set by the pre-function and the X-Request-ID correlation ID).
- Kong logs the request (status, latency, consumer) to stdout and Prometheus; the [Admin API](glossary.md#admin-api) (:8001) serves metrics internally only.

## The code that does it

**What to look at:** Global plugins across all routes: CORS (with explicit origins + header preflight), request tracing (correlation-id), security headers ([HSTS](glossary.md#hsts-http-strict-transport-security), [CSP](glossary.md#csp--permissions-policy), X-Frame-Options), and metrics collection.

```yaml
# apps/grobase/infra/docker/services/kong/conf/kong.yml:31-93
# ─── Global Plugins ──────────────────────────────────────────────
plugins:
  - name: cors
    config:
      origins:
        - __KONG_CORS_ORIGIN_APP__
        - __KONG_CORS_ORIGIN_PLAYGROUND__
        - __KONG_CORS_ORIGIN_STUDIO__
        - __KONG_CORS_ORIGIN_FRONTEND__
        # osionos second-brain Vite dev server — plain http in dev (no TLS).
        # Lets the in-browser BaaS graph mode call /query/v1/* across origins.
        - http://localhost:3001
        - http://127.0.0.1:3001
      methods: [GET, POST, PUT, PATCH, DELETE, OPTIONS]
      headers:
        # X-Baas-Tenant-Id: the in-browser mount catalog (osionos
        # liveMountCatalog → GET /admin/v1/databases) scopes by tenant header;
        # without it in the preflight allow-list that path can never work.
        [Authorization, Content-Type, Content-Profile, apikey, X-Baas-Api-Key,
         X-Baas-Tenant-Id, x-client-info, X-Request-ID, Prefer, Range, Accept,
         Accept-Profile, x-supabase-api-version]
      exposed_headers:
        [X-Kong-Upstream-Latency, X-Kong-Proxy-Latency, X-Request-ID]
      credentials: true
      max_age: 3600

  - name: correlation-id
    config:
      header_name: X-Request-ID
      generator: uuid#counter
      echo_downstream: true

  - name: response-transformer
    config:
      # Add hardening headers — covers OWASP ZAP findings:
      #  • Permissions-Policy (Low: header not set)
      #  • Cross-Origin-* round out the modern set
      #  • HSTS bumped to 2y + preload
      add:
        headers:
          - X-Content-Type-Options:nosniff
          - X-Frame-Options:DENY
          - Referrer-Policy:strict-origin-when-cross-origin
          - Permissions-Policy:accelerometer=(), autoplay=(), camera=(), display-capture=(), encrypted-media=(), fullscreen=(self), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), sync-xhr=(self), usb=(), web-share=(), xr-spatial-tracking=()
          - Cross-Origin-Opener-Policy:same-origin
          - Cross-Origin-Resource-Policy:same-site
          - Strict-Transport-Security:max-age=63072000; includeSubDomains; preload
      # Strip headers that leak server identity (ZAP: Server Leaks Version
      # Information, In Page Banner Info Leak).
      remove:
        headers:
          - Server
          - X-Powered-By
          - Via

  # ── Prometheus metrics (replaces per-service prom-client) ───────
  - name: prometheus
    config:
      status_code_metrics: true
      latency_metrics: true
      bandwidth_metrics: true
      upstream_health_metrics: true
      per_consumer: true
```

**What to look at:** Lua access hook that strips forgeable identity headers first, then base64url-decodes verified JWT payloads to extract and forward user claims (sub/email/role) as trusted headers.

```lua
# apps/grobase/infra/docker/services/kong/conf/kong.yml:95-152
  # ── Pre-Function: decode verified JWT and forward claims as headers ──
  # Kong's JWT plugin already verified the signature; we just base64-decode
  # the payload and set trusted headers so upstreams can read user identity
  # without importing jsonwebtoken themselves.
  - name: pre-function
    config:
      access:
        - |
          -- Strip any client-supplied identity headers up front; only a
          -- verified JWT below may set them. Without this, a request on the
          -- anonymous path (or with no/invalid bearer) could forge X-User-*
          -- and impersonate a user at any compat-mode upstream.
          kong.service.request.clear_header("X-User-Id")
          kong.service.request.clear_header("X-User-Email")
          kong.service.request.clear_header("X-User-Role")
          -- On the PUBLIC app routes the tenant is ALWAYS server-derived (from
          -- the verified api-key principal / JWT `sub`), never client-supplied.
          --  * /functions/ : the runtime namespaces by the first of
          --    X-Baas-Tenant-Id / X-Baas-User-Id / X-Tenant-Id / X-User-Id, so a
          --    forged *-Tenant-Id would read/deploy ANOTHER tenant's functions.
          --  * /query/ : the legacy TS query-router defaults to compat identity
          --    mode (NODE_ENV unset), which trusts a raw X-Baas-Tenant-Id; the
          --    api-key middleware re-derives the authoritative tenant from the
          --    verified key once the forged header is gone.
          -- Strip the forgeable namespace headers on both (admin/* routes are
          -- service-role + ip-restricted and the internal dispatcher invoke
          -- bypasses Kong, so neither legitimate path is affected).
          local _p = kong.request.get_path()
          if _p and (_p:sub(1, 11) == "/functions/" or _p:sub(1, 7) == "/query/") then
            kong.service.request.clear_header("X-Baas-Tenant-Id")
            kong.service.request.clear_header("X-Baas-User-Id")
            kong.service.request.clear_header("X-Tenant-Id")
          end
          local auth = kong.request.get_header("authorization")
          if not auth then return end
          local token = auth:match("^[Bb]earer%s+(.+)$")
          if not token then return end
          local parts = {}
          for p in token:gmatch("[^%.]+") do parts[#parts + 1] = p end
          if #parts < 2 then return end
          -- base64url decode the payload
          local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
          local pad = 4 - #b64 % 4
          if pad < 4 then b64 = b64 .. ("="):rep(pad) end
          local ok, payload = pcall(ngx.decode_base64, b64)
          if not ok or not payload then return end
          local cjson = require("cjson.safe")
          local claims, err = cjson.decode(payload)
          if not claims then return end
          if claims.sub then
            kong.service.request.set_header("X-User-Id", claims.sub)
          end
          if claims.email then
            kong.service.request.set_header("X-User-Email", claims.email)
          end
          if claims.role then
            kong.service.request.set_header("X-User-Role", claims.role)
          end
```

**What to look at:** REST route to PostgREST: key-auth (API key validation) + JWT (signature verification with [iss claim](glossary.md#iss-claim-issuer) check) + rate-limiting per IP.

```yaml
# apps/grobase/infra/docker/services/kong/conf/kong.yml:197-224
  - name: rest
    url: http://postgrest:3000
    routes:
      - name: rest-routes
        paths: [/rest/v1]
        strip_path: true
        plugins:
          - name: key-auth
            config:
              key_names: [apikey]
              hide_credentials: false
          - name: jwt
            config:
              header_names: [authorization]
              key_claim_name: iss
              claims_to_verify: [exp]
              run_on_preflight: false
              anonymous: __KONG_ANON_UUID__
          # Raised for the osionos bridge: a 280-page workspace open fans out
          # ~hundreds of /rest reads (page rows + per-page member-checks) at
          # once from one IP, blowing past the old 180/min cap → 429 → the
          # bridge surfaced 502/fallback and the workspace failed to load.
          - name: rate-limiting
            config:
              policy: local
              limit_by: ip
              minute: 60000
              hour: 2000000
```

**What to look at:** Legacy query-router route: key-auth + JWT verification + [request size capping](glossary.md#request-size-limiting) + per-IP rate-limiting (less aggressive than /rest/v1).

```yaml
# apps/grobase/infra/docker/services/kong/conf/kong.yml:786-816
  - name: query-router
    url: http://query-router:4001
    # /query/v1/{capabilities,engines} are the SDK introspection surface (G6):
    # both are served at the query-router ROOT and reached through this same
    # `/query/v1` route (strip_path drops the prefix) — no extra route needed.
    routes:
      - name: query-routes
        paths: [/query/v1]
        strip_path: true
        plugins:
          - name: key-auth
            config:
              key_names: [apikey]
              hide_credentials: false
          - name: jwt
            config:
              header_names: [authorization]
              key_claim_name: iss
              claims_to_verify: [exp]
              run_on_preflight: false
              anonymous: __KONG_ANON_UUID__
          - name: request-size-limiting
            config:
              allowed_payload_size: 1
              size_unit: megabytes
          - name: rate-limiting
            config:
              policy: local
              limit_by: ip
              minute: 300
              hour: 8000
```

**What to look at:** Kong container running in declarative ([db-less](glossary.md#db-less-mode)) mode on localhost:8000 (internal only, WAF is public); Admin API stays internal to prevent key leakage; Lua sandbox allows cjson.safe for JWT decoding.

```yaml
# apps/grobase/orchestrators/compose/base/gateway.yml:29-95
  kong:
    extends: { file: orchestrators/compose/base/_common.yml, service: base }
    image: ghcr.io/univers42/grobase-kong:latest # pull-fallback (built from ./build context below)
    build:
      context: ./infra/docker/services/kong
      dockerfile: Dockerfile
    container_name: mini-baas-kong
    env_file: [.env]
    ports:
      # Kong is now internal — WAF is the public entrypoint.
      # Keep 8000 exposed on localhost for direct dev access.
      - "127.0.0.1:${KONG_HTTP_PORT:-8000}:8000"
      # SECURITY: the Admin API (:8001) is NOT published to the host — in db-less
      # mode `GET /key-auths` returns the cleartext anon + service_role keys (and
      # /jwts the JWT secret). It stays on 0.0.0.0:8001 inside the container so
      # Prometheus can scrape `kong:8001` over the internal network, but no host
      # process (or host-bound SSRF) can reach it. Re-publish only for debugging.
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /tmp/kong.yml
      KONG_PROXY_ACCESS_LOG: /dev/stdout
      KONG_ADMIN_ACCESS_LOG: /dev/stdout
      KONG_PROXY_ERROR_LOG: /dev/stderr
      KONG_ADMIN_ERROR_LOG: /dev/stderr
      KONG_ADMIN_LISTEN: "0.0.0.0:8001"
      KONG_HEADERS: "off"
      KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE: "1m"
      KONG_NGINX_HTTP_CLIENT_BODY_TIMEOUT: "1s"
      KONG_NGINX_WORKER_PROCESSES: "1"
      KONG_MEM_CACHE_SIZE: "64m"
      KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: "cjson.safe"
      JWT_SECRET: ${JWT_SECRET}
      GOTRUE_JWT_ISS: ${API_EXTERNAL_URL:-http://localhost:8000/auth/v1}
      KONG_ANON_UUID: ${KONG_ANON_UUID:-cd4f782c-ac87-5081-b322-b54834d15651}
    volumes:
      - ./infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro
    command: >
      sh -ec '
        sed \
          -e "s|__KONG_PUBLIC_API_KEY__|$${KONG_PUBLIC_API_KEY}|g" \
          -e "s|__KONG_SERVICE_API_KEY__|$${KONG_SERVICE_API_KEY}|g" \
          -e "s|__KONG_CORS_ORIGIN_APP__|$${KONG_CORS_ORIGIN_APP}|g" \
          -e "s|__KONG_CORS_ORIGIN_PLAYGROUND__|$${KONG_CORS_ORIGIN_PLAYGROUND}|g" \
          -e "s|__KONG_CORS_ORIGIN_STUDIO__|$${KONG_CORS_ORIGIN_STUDIO}|g" \
          -e "s|__KONG_CORS_ORIGIN_FRONTEND__|$${KONG_CORS_ORIGIN_FRONTEND}|g" \
          -e "s|__JWT_SECRET__|$${JWT_SECRET}|g" \
          -e "s|__GOTRUE_JWT_ISS__|$${GOTRUE_JWT_ISS}|g" \
          -e "s|__KONG_ANON_UUID__|$${KONG_ANON_UUID}|g" \
          /etc/kong/kong.yml.tmpl > /tmp/kong.yml;
        exec /docker-entrypoint.sh kong docker-start
      '
    healthcheck:
      test: ["CMD-SHELL", "kong health"]
      interval: 5s
      timeout: 3s
      start_period: 20s
      retries: 10
    depends_on:
      gotrue:
        condition: service_healthy
      postgrest:
        condition: service_started
      realtime:
        condition: service_healthy
        required: false
    mem_limit: 1g
    cpus: 1.0
```

## Where it sits in the request flow

Kong is the entry point. Every request hits Kong first before reaching any upstream service. The flow is: client → Kong (auth, header stripping, routing) → upstream (PostgREST, query-router, data plane, auth, storage, etc.) → response back through Kong. Kong has no dependency on the upstreams for its core job (routing, auth validation); it does depend on the JWT secret from [GoTrue](glossary.md#gotrue) (the auth service) to verify signatures. The data plane, query-router, and other upstreams depend on Kong to deliver the X-User-Id header so they can enforce [owner-scoping](glossary.md#owner-scoping) via [RLS](glossary.md#rls-row-level-security) or explicit filtering. That same trusted header chain is what makes [tenant isolation](glossary.md#tenant-isolation) hold across every engine — Kong is the single place where a client claim becomes a verified identity.

## Remember this

> Kong strips all identity headers from the client, validates the JWT, decodes it, sets X-User-Id from the sub claim, and forwards that to upstreams so they can trust it—the only way an upstream sees an identity header is if Kong verified a JWT first.

---
**See also:** [query-router-ApiKeyMiddleware.md](query-router-ApiKeyMiddleware.md) · [owner_isolation.md](owner_isolation.md) · [rls.md](rls.md) · [ABAC_RBAC.md](ABAC_RBAC.md) · [Glossary](glossary.md)
