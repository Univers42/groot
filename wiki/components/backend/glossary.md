# Glossary

Shared vocabulary for the backend component wiki — [reverse_proxy.md](reverse_proxy.md), [query-router-ApiKeyMiddleware.md](query-router-ApiKeyMiddleware.md), [owner_isolation.md](owner_isolation.md), [rls.md](rls.md), and [ABAC_RBAC.md](ABAC_RBAC.md). Each term has a plain-English definition and one line on how grobase uses it. Headings are kebab-cased for `glossary.md#anchor` deep links.

### AAL (Authentication Assurance Level)
**Plain English.** A measure of MFA strength: aal1 (password/email), aal2 (TOTP), aal3 (WebAuthn / hardware key).
**In grobase.** An ABAC condition: `conditions['aal']: 'aal2'` restricts a policy to MFA'd callers; `attrs['aal']` defaults to `aal1` if the query-router supplies none (ABAC_RBAC.md).

### ABAC (Attribute-Based Access Control)
**Plain English.** Authorization by role membership AND request-level attributes (time, IP, MFA level, ownership), so the same role can be allowed or denied depending on the request.
**In grobase.** `PERMISSION_MODE=abac` (default): the PDP evaluates user roles plus JSONB conditions (time_window, ip_cidr, aal, owner, resource_id) when `PERMISSION_CONDITIONS_ENABLED=1` (ABAC_RBAC.md).

### ACID
**Plain English.** The transaction guarantee: Atomic (all-or-nothing), Consistent (rules enforced), Isolated (no dirty reads), Durable (persisted).
**In grobase.** The `/query/v1/txn` endpoint exposes true ACID on a single mount via the Rust data plane; multi-mount ACID is not offered (would require 2PC).

### Admin API
**Plain English.** Kong's management endpoint, separate from the proxy port, used to configure routes, plugins, and consumers.
**In grobase.** Kong's Admin API (`:8001`) is deliberately not exposed to the host (it would leak API keys and JWT secrets); only internal Prometheus scraping reaches it (reverse_proxy.md).

### Admin bypass (DATA_PLANE_ADMIN_BYPASS / F2)
**Plain English.** A flag-gated feature (off by default) letting callers with an admin role/scope read or write across owners.
**In grobase.** The `is_admin()` check gates whether the bypass applies; with the flag off, owner-scoping is enforced for everyone (owner_isolation.md).

### Anon role
**Plain English.** The unauthenticated PostgREST role applied to requests that carry no valid user token.
**In grobase.** PostgREST `SET ROLE`s to `anon` per request; secret tables are revoked from `anon` entirely, and RLS shows it nothing unless a policy allows it (rls.md).

### API gateway
**Plain English.** The single front-door service that authenticates, rate-limits, routes, and shapes headers for every API request before it reaches a backend.
**In grobase.** Kong is the API gateway: it validates auth, strips/adds identity headers, enforces rate and size limits, and routes by path prefix to upstreams (reverse_proxy.md).

### API key
**Plain English.** A pre-shared secret string (here, `mbk_XXXX` format) an app sends to authenticate; it carries no embedded identity of its own.
**In grobase.** Resolved by the control plane's `/v1/keys/verify` (Argon2id or fast-hash) to a `tenant_id` + scopes; Kong's key-auth plugin also accepts it at the edge. An API key becomes the owner (`api-key:<keyId>`) unless a Bearer JWT overrides it (query-router-ApiKeyMiddleware.md).

### Application proxy
**Plain English.** A service that sits between the reverse proxy and the data plane, handling identity verification and query routing.
**In grobase.** The query-router is the application proxy: it verifies API keys/JWTs, mints signed envelopes, and forwards to the Rust data plane or legacy TS adapters (query-router-ApiKeyMiddleware.md).

### Argon2id
**Plain English.** A memory-hard password-hashing algorithm that resists brute force by demanding both time and memory.
**In grobase.** The legacy API-key hash scheme in the control plane (`keys_verify.go`). Keys are lazily upgraded to a faster scheme on first verify when `KEY_HASH_UPGRADE` is on, so the fleet drains off Argon2id without re-provisioning.

### Authenticator role
**Plain English.** The non-superuser login role a service connects as, then switches away from per request.
**In grobase.** Created in migration 065 as the only role PostgREST connects as; it is `NOBYPASSRLS` and `NOINHERIT`, then `SET ROLE`s to anon/authenticated/service_role per JWT claim (rls.md).

### Base64url encoding
**Plain English.** A URL-safe base64 variant that swaps `+`/`/` for `-`/`_` so tokens survive being placed in URLs.
**In grobase.** Kong's Lua pre-function decodes the JWT payload (middle segment) by converting base64url back to base64 and calling `ngx.decode_base64` (reverse_proxy.md).

### Bearer JWT
**Plain English.** An `Authorization: Bearer <token>` header carrying a signed claim set; opaque to plain HTTP middleware until verified.
**In grobase.** When a GoTrue Bearer JWT rides alongside an API key, the middleware verifies it (HS256, constant-time), extracts `sub` and role, and makes the user the owner instead of the app key — per-user access without rotating keys (query-router-ApiKeyMiddleware.md).

### Byte-parity
**Plain English.** Two versions of a system producing identical results for the same input, so either can replace the other with no behavior change.
**In grobase.** With `PERMISSION_CONDITIONS_ENABLED=0`, migration 063's 7-arg `has_permission()` is byte-identical to migration 007's 4-arg version (ABAC_RBAC.md).

### Capability
**Plain English.** Whether an engine supports a given operation (read, write, batch, aggregate, transactions, DDL).
**In grobase.** The `/v1/capabilities` endpoint exposes per-engine capabilities; requesting an unsupported one (e.g. aggregate on Redis) surfaces as `UnprocessableEntityException` (422).

### CDC (Change Data Capture)
**Plain English.** Streaming a database's row-level changes (inserts/updates/deletes) as an event log for downstream consumers.
**In grobase.** Backs realtime: committed changes flow through the outbox so subscribed clients receive updates; the service_role drains the outbox bypassing RLS.

### Claims
**Plain English.** The name/value facts encoded inside a JWT (user ID, email, role, expiry, issuer).
**In grobase.** Kong decodes claims and forwards them as `X-User-*` headers; PostgREST stores them in the `request.jwt.claims` GUC so `auth.current_user_id()` and RLS policies can read them (rls.md, reverse_proxy.md).

### Column-level privilege
**Plain English.** A GRANT scoped to specific columns of a table rather than the whole table.
**In grobase.** Secret tables (`tenant_databases`, `tenant_api_keys`) are revoked from anon/authenticated entirely, so even if RLS matched, no column privilege exists to leak connection strings (rls.md).

### Condition evaluation
**Plain English.** Testing whether a policy's stored conditions (time, IP, MFA, owner, resource) are satisfied by a request's attributes.
**In grobase.** `auth.eval_conditions(conditions JSONB, attrs JSONB)` in migration 063: strict on known keys (time_window, ip_cidr, aal, owner, resource_id), ignoring stored-row keys like owner_only/mask (ABAC_RBAC.md).

### Connection pool
**Plain English.** A reusable set of open database connections shared across requests to avoid the cost of reconnecting each time.
**In grobase.** The Rust data plane owns per-mount pools; owner-scoping is set per request (via GUCs) and never cached on the connection, so one pool can safely serve 10K tenants (owner_isolation.md).

### Constant-time compare
**Plain English.** A comparison that takes the same time regardless of where the inputs differ, defeating timing attacks.
**In grobase.** The middleware uses `timingSafeEqual` for JWT signature checks, and the control plane for key-hash checks, so response time leaks no partial secret (query-router-ApiKeyMiddleware.md).

### Control plane
**Plain English.** The service that manages metadata: tenants, API keys, mounts, schema, provisioning, quotas, billing.
**In grobase.** The Go control plane hosts `/v1/keys/verify`, validates cleartext keys against stored hashes, returns `tenant_id` + scopes, and drives provisioning and migrations (query-router-ApiKeyMiddleware.md).

### Correlation ID
**Plain English.** A unique ID attached to a request and threaded through every service so all its log lines can be tied together.
**In grobase.** Kong's correlation-id plugin generates a per-request UUID in `X-Request-ID` and echoes it in the response (reverse_proxy.md).

### CORS (Cross-Origin Resource Sharing)
**Plain English.** The browser mechanism that lets a page on one origin call an API on another, gated by explicit response headers.
**In grobase.** Kong's cors plugin whitelists specific app/playground origins, allows `Authorization` + `X-Baas-*` headers in preflight, and sets `max_age` to cache the policy (reverse_proxy.md).

### CSP / Permissions-Policy
**Plain English.** Headers that restrict which browser capabilities (camera, mic, payment) and script sources a page may use, limiting XSS and capability leaks.
**In grobase.** Kong adds a `Permissions-Policy` that disables most features by default, allowing only fullscreen and sync-xhr to self (reverse_proxy.md).

### Cache TTL
**Plain English.** Time-to-live: how long a cached value stays fresh before it must be re-fetched.
**In grobase.** API-key verify caches responses for 30s (`API_KEY_VERIFY_CACHE_TTL_MS`); bursts skip the control-plane roundtrip. The TTL is also the revocation-staleness window (query-router-ApiKeyMiddleware.md).

### Data plane
**Plain English.** The service that actually executes queries against the real databases (Postgres, Mongo, Redis, …).
**In grobase.** The Rust data-plane-router executes queries with the identity envelope embedded in the request, owns the per-mount pools, and enforces owner-scoping via RLS or app logic (owner_isolation.md).

### DatabaseMount
**Plain English.** A configured connection target: engine type, DSN/credential reference, isolation strategy, and tenant.
**In grobase.** Each mount carries an isolation strategy that decides how its tenants are separated (owner_isolation.md). See also **mount**.

### Db-less mode
**Plain English.** A Kong mode where all routes, plugins, and consumers come from a static YAML file instead of a backing database.
**In grobase.** Kong runs db-less; `kong.yml` is templated at startup to inject API keys and JWT secrets (reverse_proxy.md).

### DbPerTenant
**Plain English.** An isolation strategy giving each tenant its own physical database.
**In grobase.** One of the per-mount isolation strategies; the strongest separation, used where tenants need a fully distinct database (owner_isolation.md).

### Declarative config
**Plain English.** Defining a system's entire state upfront in a file applied once at startup, rather than mutating it live.
**In grobase.** Kong loads the templated `kong.yml` at startup; changes require a container restart — acceptable for the stateless gateway plane (reverse_proxy.md).

### Default-off
**Plain English.** A flag that defaults to false, so adding it changes nothing until it is explicitly enabled.
**In grobase.** `PERMISSION_CONDITIONS_ENABLED` defaults to `0`; `has_permission()` ignores JSONB conditions unless it is `1`, preserving pre-063 behavior (ABAC_RBAC.md).

### Defense in depth
**Plain English.** Layering multiple independent controls so one breached layer does not expose the asset.
**In grobase.** PostgREST + RLS stack several layers: `NOBYPASSRLS` (role can't escape RLS), `FORCE ROW LEVEL SECURITY` (policies apply even to the owner), and column grants that revoke secrets from public roles (rls.md).

### Deny-first
**Plain English.** A conflict rule: when both an allow and a deny policy match, deny wins.
**In grobase.** `has_permission` returns false the moment a matching `deny` is seen; ordering `BY priority DESC, effect ASC` ensures deny is checked first at equal priority (ABAC_RBAC.md).

### Effect
**Plain English.** A policy's outcome: allow or deny.
**In grobase.** `resource_policies.effect` is `'allow'` or `'deny'`; deny wins immediately at equal priority, and a later allow after a non-matching conditional allow does not grant (ABAC_RBAC.md).

### Engine adapter
**Plain English.** A driver that translates a generic query into one engine's native syntax, implementing a shared interface so callers stay engine-agnostic.
**In grobase.** The Rust data plane ships adapters for postgres, mysql, mongo, mssql, sqlite, redis, http, and dynamodb, all implementing the same `EngineAdapter` trait and enforcing owner-scoping identically (owner_isolation.md).

### Exp claim (expiration)
**Plain English.** The JWT field giving the timestamp after which the token is no longer valid.
**In grobase.** Kong verifies `exp` is in the future; an expired token is rejected even with a valid signature (reverse_proxy.md).

### Fail closed
**Plain English.** A security posture where errors or unavailability deny access rather than defaulting to allow.
**In grobase.** If the permission-engine is unreachable, query-router throws `ServiceUnavailableException` (503) instead of silently permitting the operation (ABAC_RBAC.md).

### Field mask
**Plain English.** A directive to hide or redact specific fields in a response even when access is granted.
**In grobase.** An ABAC feature: `conditions['mask']: {hide: ['secret'], redact: {email: '***'}}` resolved by `decisions.resolveMask()` before data is returned (ABAC_RBAC.md).

### Flag-gating
**Plain English.** Mounting new or risky behavior behind a flag that defaults off, so a missing flag means the old behavior unchanged.
**In grobase.** Used throughout — `PERMISSION_CONDITIONS_ENABLED`, `RUST_DATA_PLANE_FORWARD`, `DATA_PLANE_ADMIN_BYPASS`, `API_KEY_ABAC_ENABLED` — each defaults off so production keeps the proven path (ABAC_RBAC.md, owner_isolation.md).

### FNV-1a hash
**Plain English.** A fast, non-cryptographic 64-bit hash function.
**In grobase.** Used by `safe_schema` to append an 8-char suffix to a sanitized tenant id — a stable, dependency-free, zero-allocation way to avoid cross-tenant schema collisions (owner_isolation.md).

### FORCE ROW LEVEL SECURITY
**Plain English.** A table setting that applies RLS policies even to the table owner and superusers, who would otherwise bypass plain `ENABLE RLS`.
**In grobase.** Migration 065 forces RLS on all data tables so PostgREST cannot escape policies by being the creator; paired with `NOBYPASSRLS` for defense in depth (rls.md).

### GoTrue
**Plain English.** An open-source authentication service that mints JWTs and manages user sessions (email/password, OAuth, TOTP).
**In grobase.** Serves `/auth/v1` behind Kong; its issuer URL must match the JWT `iss` claim for a token to be trusted. The query-router can optionally verify a GoTrue Bearer JWT to elevate the owner from app-key to user (reverse_proxy.md, query-router-ApiKeyMiddleware.md).

### GUC (Grand Unified Configuration)
**Plain English.** A PostgreSQL session variable, set per connection/transaction and readable from SQL, scoped to that session only.
**In grobase.** The data plane sets GUCs (`rls.tenant_id`, `rls.user_id`, `search_path`) before each query so RLS policies can read the owner and filter rows; PostgREST holds the JWT in the `request.jwt.claims` GUC (owner_isolation.md, rls.md).

### Header forgery / header injection
**Plain English.** An attack where a client sends a spoofed `X-User-*`/`X-Tenant-*` header to impersonate another user or tenant.
**In grobase.** Kong's pre-function strips these headers unconditionally before processing, so only a verified JWT can set identity (reverse_proxy.md).

### HMAC
**Plain English.** A keyed cryptographic signature over a message, verifiable by anyone holding the same shared secret.
**In grobase.** Used (SHA-256) for service-to-service auth between query-router and control plane (`X-Service-Auth`) and to sign/verify identity envelopes minted by the middleware (query-router-ApiKeyMiddleware.md).

### Hot path
**Plain English.** Code that runs on every request, where performance matters most.
**In grobase.** `Isolation::scope` is a branchless match on a `Copy` enum to stay allocation-free; the PDP decision is TTL-cached and fails closed (owner_isolation.md, ABAC_RBAC.md).

### HSTS (HTTP Strict-Transport-Security)
**Plain English.** A header telling browsers to always use HTTPS for a domain, preventing downgrade to HTTP.
**In grobase.** Kong's response-transformer adds `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` (reverse_proxy.md).

### Identity envelope
**Plain English.** A cryptographically signed set of HTTP headers bundling tenant, user, role, scopes, and a nonce to prove the caller's identity.
**In grobase.** Minted by the api-key middleware after verifying a key or JWT, signed over a canonical string (method, path, tenant, user, role, body hash); downstream AuthGuard verifies it, and nonce dedup blocks replay (query-router-ApiKeyMiddleware.md). See also **signed envelope**.

### Identity helper
**Plain English.** A SQL function that reads the caller's identity from request context and returns a type-safe value.
**In grobase.** `auth.current_user_id()` and `auth.current_tenant_id()` read `request.jwt.claims` (set by PostgREST) and are used in every RLS policy (rls.md).

### Idempotency
**Plain English.** A property where repeating the same operation has the same effect as doing it once, so retries are safe.
**In grobase.** `PUT`/`DELETE` are idempotent by verb; unsafe retries accept an idempotency key per the api-convention rule, and root SQL migrations are written to be idempotent.

### IP CIDR
**Plain English.** A network range such as `10.0.0.0/8` used to restrict access to callers from specific subnets.
**In grobase.** `conditions['ip_cidr']: ['10.0.0.0/8','127.0.0.0/8']` evaluated with Postgres `inet <<=` against `attrs['ip']` (ABAC_RBAC.md).

### Iss claim (issuer)
**Plain English.** The JWT field naming who signed the token, used to confirm it came from the expected source.
**In grobase.** Kong's JWT plugin requires `iss` to match the registered GoTrue issuer (`API_EXTERNAL_URL`); a different issuer is rejected (reverse_proxy.md).

### Isolation strategy
**Plain English.** The per-mount model for separating tenants: by row, by schema, by database, or externally owned.
**In grobase.** Set per mount — `SharedRls` (RLS on a shared schema, default), `SchemaPerTenant`, `DbPerTenant`, `TenantOwned` (external DB). Owner-scoping happens per request regardless (owner_isolation.md).

### JSONB conditions
**Plain English.** Structured rules stored as a JSON document and evaluated against request attributes at decision time.
**In grobase.** `resource_policies.conditions` (JSONB) holds time_window, ip_cidr, aal, owner, resource_id; evaluated by `auth.eval_conditions` only when conditions are enabled (ABAC_RBAC.md).

### JWT (JSON Web Token)
**Plain English.** A digitally signed, URL-safe token encoding claims (user ID, email, role) that a client passes in requests without ever seeing the signing secret.
**In grobase.** Issued by GoTrue with `iss = API_EXTERNAL_URL`; Kong verifies the signature and forwards decoded claims as headers, and PostgREST uses them for RLS (reverse_proxy.md, rls.md).

### Kong
**Plain English.** A high-performance API gateway/reverse proxy (built on Nginx) that authenticates, routes, and shapes traffic at the edge.
**In grobase.** The public entry point: validates auth, strips/adds headers, enforces rate and size limits, then forwards by path prefix to PostgREST, GoTrue, the query-router, and the data plane (reverse_proxy.md).

### Least privilege
**Plain English.** Granting a role only the minimum permissions it needs.
**In grobase.** Migration 065 (`065_least_privilege_rls`) strips public-role grants on secret tables so anon/authenticated see nothing unless RLS explicitly allows it (rls.md).

### Lua pre-function / Lua sandbox
**Plain English.** A restricted Lua execution environment in Kong, permitting only whitelisted library calls so plugin code can't break out.
**In grobase.** Kong's pre-function runs in the sandbox to strip forged identity headers and decode the JWT payload, with `cjson.safe` allowed to parse the claims (reverse_proxy.md).

### Mount
**Plain English.** A connected database target attached to a tenant — engine, credentials, and isolation in one descriptor.
**In grobase.** Each mount carries its own isolation strategy and pool; the `/query/v1/txn` ACID guarantee is single-mount only (owner_isolation.md). See also **DatabaseMount**.

### Nginx
**Plain English.** A high-performance web server and reverse proxy that Kong is built on.
**In grobase.** Kong sits on Nginx; worker and buffer settings are tuned via `KONG_NGINX_*` env vars (reverse_proxy.md).

### NOBYPASSRLS
**Plain English.** A Postgres role attribute forbidding the role from ever bypassing RLS, even if it later gains superuser.
**In grobase.** PostgREST's authenticator role is created `NOBYPASSRLS` so it can never escape RLS regardless of future privilege escalation (rls.md).

### NOINHERIT
**Plain English.** A Postgres role attribute that stops a role from auto-acquiring its member roles' privileges on login.
**In grobase.** The authenticator is `NOINHERIT`, so membership in anon/authenticated grants nothing unless an explicit `SET ROLE` is issued (rls.md).

### Nonce
**Plain English.** A random, single-use value in a signed message that blocks replay of a captured message.
**In grobase.** Every signed identity envelope carries `x-baas-nonce`; the middleware dedups nonces per key-id within the max-skew window, rejecting replays (query-router-ApiKeyMiddleware.md).

### Owner principal
**Plain English.** The effective data owner for a single request: the authenticated `user_id` if present, otherwise the `tenant_id` (the `user_id ?? tenant_id` rule).
**In grobase.** Resolved per request and embedded in every query so reads/writes are scoped to that owner alone (owner_isolation.md).

### Owner-scoping
**Plain English.** A per-request filter restricting a query's rows to those owned by the authenticated caller, enforced on every query (never via connection state).
**In grobase.** The data plane enforces it via Postgres RLS (SharedRls) or schema/db isolation; the owner is an API key (`api-key:<keyId>`) or a user (`user:<sub>`), resolved afresh each request (owner_isolation.md, rls.md).

### Parity
**Plain English.** The state where two implementations behave identically — same results, errors, and (ideally) performance.
**In grobase.** The m18 gates exercise both the TS and Rust paths to prove identical rows, errors, and rowCount before cutover (owner_isolation.md).

### Path prefix routing
**Plain English.** Routing requests by the leading segment of the URL path.
**In grobase.** Kong routes `/auth/v1` → GoTrue, `/rest/v1` → PostgREST, `/query/v1` → query-router, `/data/v1` → Rust data plane (reverse_proxy.md).

### PDP (Policy Decision Point)
**Plain English.** The service that evaluates whether an operation is allowed before it runs.
**In grobase.** The permission-engine NestJS service: it calls SQL `has_permission()` and resolves field masks on the hot path before the query-router forwards to the data plane (ABAC_RBAC.md).

### Policy bundle
**Plain English.** A serialized snapshot of all user-role assignments and resource policies handed to an evaluator.
**In grobase.** `BundlesService.latest()` reads `user_roles` + `resource_policies` and returns `PolicyBundle {generated_at, user_roles[], policies[]}` to the Rust ABAC engine (ABAC_RBAC.md).

### PostgREST
**Plain English.** A service that auto-exposes a PostgreSQL schema as a REST API, delegating access control to the database via roles and RLS.
**In grobase.** Reached behind Kong at `/rest/v1`; it connects as the authenticator role and `SET ROLE`s to anon/authenticated/service_role per JWT claim, so RLS does the enforcing (rls.md).

### Priority
**Plain English.** A numeric ordering for policy evaluation — higher priority checked first.
**In grobase.** `resource_policies.priority` (INT), ordered `DESC` then effect `ASC` (deny-first tie-break) in the `has_permission` query (ABAC_RBAC.md).

### Prometheus metrics
**Plain English.** A time-series metrics format scraped by monitoring systems for latency, error rates, and request counts.
**In grobase.** Kong's prometheus plugin emits latency, bandwidth, and per-consumer metrics on `/metrics` via the Admin API (`:8001`) (reverse_proxy.md).

### Query router (query-router)
**Plain English.** The TypeScript service that receives HTTP requests, resolves the API key/JWT to an identity, and forwards the query downstream with that identity attached.
**In grobase.** It verifies credentials via the middleware, mints signed envelopes, calls the PDP, and routes to the Rust data plane (`RUST_DATA_PLANE_FORWARD=1`) or legacy TS adapters (query-router-ApiKeyMiddleware.md).

### /query/v1/txn
**Plain English.** The endpoint exposing a database transaction with full ACID guarantees over a single connection.
**In grobase.** Backed by the Rust data plane's transaction API on one mount; multi-mount transactions are not offered (would need 2PC).

### Rate-limiting
**Plain English.** A gateway guard that rejects requests above a rate threshold to curb DoS and abuse.
**In grobase.** Kong applies per-IP limits per path — e.g. `/rest/v1` ~60k/min, `/query/v1` ~300/min (reverse_proxy.md).

### RBAC (Role-Based Access Control)
**Plain English.** Authorization by role membership alone, without evaluating request-level conditions.
**In grobase.** `PERMISSION_MODE=rbac`: fast and stateless, matching users → roles → policies (allow/deny) with no JSONB conditions (ABAC_RBAC.md).

### Replay attack
**Plain English.** Resending a captured-but-valid message (a JWT or signed envelope) to the server later.
**In grobase.** Blocked by the per-envelope nonce: the middleware tracks seen nonces per key-id within the max-skew window and rejects duplicates (query-router-ApiKeyMiddleware.md).

### Request context
**Plain English.** The identity attributes (user, tenant, role, claims) that describe the client for one request's lifetime.
**In grobase.** PostgREST builds it from the verified JWT, setting `request.jwt.claims` so RLS policies in the same query can read `auth.current_user_id()` (rls.md).

### Request-size limiting
**Plain English.** A gateway check rejecting payloads above a byte limit, guarding against memory exhaustion.
**In grobase.** Kong caps `/query/v1` and `/rest/v1` at 1 MB; `/storage/v1` allows 10 MB for uploads (reverse_proxy.md).

### RequestIdentity
**Plain English.** A verified identity structure holding tenant_id, user_id, roles, scopes, and source, resolved once per request.
**In grobase.** Produced from the API key/JWT via the control plane; the data plane executes every query with this identity embedded (owner_isolation.md).

### Resource ID
**Plain English.** A specific row/object identifier used for per-instance permission checks.
**In grobase.** `context.resourceId` flows to the PDP as `attrs['resource_id']`; policies with `conditions['resource_id']` or `resource_id_in` gate per row (ABAC_RBAC.md).

### Resource policy
**Plain English.** A rule that a role may perform certain actions on a resource, optionally gated by conditions and masks.
**In grobase.** `public.resource_policies`: role_id, resource_type, resource_name, actions[], effect, priority, conditions JSONB (ABAC_RBAC.md).

### Reverse proxy
**Plain English.** A server that receives client requests and forwards them to backend services, optionally rewriting headers, rate-limiting, or caching.
**In grobase.** Kong is the reverse proxy and the public entry point; every request enters through it before reaching any upstream (reverse_proxy.md).

### RLS (Row-Level Security)
**Plain English.** A Postgres feature that filters which rows a query can see/modify based on a per-table policy and the active role — enforced by the database, not the app.
**In grobase.** Tenant-facing tables enable and FORCE RLS; policies use `auth.current_user_id()` to scope each query to the caller's own rows, and the data plane sets the owner via GUCs for SharedRls mounts (rls.md, owner_isolation.md).

### Role
**Plain English.** A named group of permissions assignable to users.
**In grobase.** `public.roles`: id, name (unique), description, is_system, metadata. Seed roles: admin, user, guest, moderator, service_role (ABAC_RBAC.md).

### Safe schema derivation
**Plain English.** A collision-free naming function for tenant schemas/namespaces.
**In grobase.** `safe_schema` sanitizes tenant_id to `[a-z0-9_]`, truncates at 40 chars, and appends an 8-char FNV hash of the raw id, neutralizing injection before interpolating into `SET search_path` (owner_isolation.md).

### Scope (API-key scope)
**Plain English.** A permission grant on an API key indicating allowed operations (read, write, admin).
**In grobase.** With `API_KEY_ABAC_ENABLED=0` (default) scopes are checked directly; when enabled, scopes project to `apikey:read/write/admin` roles for the PDP (ABAC_RBAC.md, query-router-ApiKeyMiddleware.md).

### ScopeDirective
**Plain English.** An engine-neutral per-request instruction telling each adapter how to apply isolation.
**In grobase.** `None` (no-op), `SetSearchPath` (Postgres), or `UseNamespace` (MySQL/MongoDB/Redis) — the schema namespace mechanism per engine (owner_isolation.md).

### Schema introspection
**Plain English.** Querying a database to discover its structure: tables, columns, types, keys.
**In grobase.** `/v1/schema` returns a `RustSchemaDescriptor` (tables + columns + PKs + FKs + enum values), engine-agnostic across Postgres/Mongo/etc.

### Schema namespace
**Plain English.** The logical container that isolates one tenant's data.
**In grobase.** A real Postgres schema (`search_path`), a MySQL/MongoDB database name, or a Redis key-prefix — implemented by ScopeDirective (owner_isolation.md).

### SchemaPerTenant
**Plain English.** An isolation strategy giving each tenant its own schema within a shared database.
**In grobase.** One of the per-mount strategies; sits between SharedRls and DbPerTenant in separation strength (owner_isolation.md).

### Service role
**Plain English.** A privileged role used for trusted server-side work that bypasses RLS.
**In grobase.** The Go control plane and the realtime outbox use `service_role` JWTs to bypass RLS for bulk operations anon/authenticated cannot perform (rls.md).

### Service token
**Plain English.** A shared secret for internal service-to-service auth, never exposed to clients.
**In grobase.** The query-router signs `/v1/keys/verify` calls with `INTERNAL_SERVICE_TOKEN` (HMAC, or `X-Service-Token` in static mode) and sends `X-Service-Token` to the PDP, which validates it (query-router-ApiKeyMiddleware.md, ABAC_RBAC.md).

### SET ROLE
**Plain English.** A Postgres command that switches the session's active role, changing which privileges and RLS policies apply.
**In grobase.** PostgREST runs `SET ROLE anon/authenticated/service_role` per request from the verified JWT's role claim (rls.md).

### Shadow mode
**Plain English.** Running a new system in parallel with the old, taking traffic but not yet authoritative.
**In grobase.** `RUST_DATA_PLANE_FORWARD` gates whether queries reach Rust; `DATA_PLANE_ROUTER_PRODUCT_MODE=shadow` logs Rust results while still returning TS results. Both off by default, keeping TS the authority (owner_isolation.md).

### SHARE_POOLS
**Plain English.** A flag controlling whether tenants share a single connection pool versus getting dedicated pools.
**In grobase.** When pools are shared, per-request owner-scoping (GUC-set identity, never connection-cached) is what makes one pool safe for many tenants (owner_isolation.md).

### SharedRls
**Plain English.** An isolation strategy where all tenants' rows live in one schema and are separated only by RLS policy.
**In grobase.** The default per-mount strategy; the data plane sets `rls.user_id`/`rls.tenant_id` GUCs per request so RLS filters each query to its owner (owner_isolation.md, rls.md).

### Signed envelope
**Plain English.** An identity envelope protected by an HMAC signature rather than raw headers.
**In grobase.** Downstream services trust requests with `source=signed_envelope` because a trusted middleware minted them after verification; raw unsigned headers are rejected in strict mode (query-router-ApiKeyMiddleware.md).

### Strict mode
**Plain English.** An auth policy accepting only signed, verified identity envelopes and rejecting raw identity headers.
**In grobase.** `IDENTITY_HEADER_MODE=strict` (production default) blocks forged `X-Baas-*` headers; compat mode (dev) accepts both signed and unsigned for testing (query-router-ApiKeyMiddleware.md).

### Strip path
**Plain English.** A router option that removes the matched prefix before forwarding, so `/rest/v1/users` reaches the backend as `/users`.
**In grobase.** Most Kong routes set `strip_path: true`; a few (`/data/v1`, `/storage/v1/sign`) keep the full path with `false` (reverse_proxy.md).

### Superuser
**Plain English.** A Postgres role with all privileges that bypasses RLS unless explicitly `NOBYPASSRLS`.
**In grobase.** PostgREST never connects as `postgres`; doing so would bypass all RLS and defeat tenant isolation (rls.md).

### Tenant
**Plain English.** A multi-tenant workspace/account; all data, users, and API keys belong to exactly one tenant.
**In grobase.** Resolved from an API key or JWT, stamped on every request, and isolated at the database level (RLS or schema-per-tenant). See also **tenant ID**, **tenant isolation** (owner_isolation.md).

### Tenant ID
**Plain English.** The unique identifier of a tenant.
**In grobase.** Resolved from the verified key/JWT and passed to the data plane's owner-scoping; also the default owner principal when no user is present (owner_isolation.md).

### Tenant isolation
**Plain English.** Keeping each tenant's data logically or physically separate so no tenant can reach another's.
**In grobase.** Kong's header-stripping prevents tenant-id spoofing; the data plane re-derives the authoritative tenant from the verified credential and enforces it per request (reverse_proxy.md, owner_isolation.md).

### Tenant self-serve
**Plain English.** APIs that let a tenant manage itself with no `{id}` in the path, so cross-tenant access is impossible by construction.
**In grobase.** Routes like `/v1/tenants/me` resolve the tenant from the credential, never from a path parameter (per the api-convention rule).

### TenantOwned
**Plain English.** An isolation strategy where the tenant's data lives in an external database they own.
**In grobase.** One of the per-mount strategies; grobase connects to the tenant-supplied DSN rather than hosting the data (owner_isolation.md).

### Time window
**Plain English.** A condition restricting access to a time range (after a start, before an end, or both).
**In grobase.** `conditions['time_window']: {after, before}` evaluated against `now()` in `auth.eval_conditions` (ABAC_RBAC.md).

### TTL cache
**Plain English.** A short-lived cache whose entries expire after N seconds.
**In grobase.** The query-router TTL-caches PDP decisions per user/operation/resource to avoid hammering the permission-engine within the window (ABAC_RBAC.md).

### User role
**Plain English.** An assignment of a role to a user, optionally expiring at a future date.
**In grobase.** `public.user_roles`: user_id, role_id, expires_at; the PDP filters stale assignments via `(expires_at IS NULL OR expires_at > now())` (ABAC_RBAC.md).

### Wildcard resource
**Plain English.** A policy matching all resource types or names, denoted `*`.
**In grobase.** `resource_policies` with `resource_type='*'` or `resource_name='*'` match any engine/table — e.g. the admin role's wildcard ALLOW (ABAC_RBAC.md).
