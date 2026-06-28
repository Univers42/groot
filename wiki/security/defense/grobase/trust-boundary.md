# Trust Boundary — grobase (the BaaS backend)

> Every request crosses two enforced trust boundaries before touching data: the Kong edge strips and re-derives all identity headers from a signature-verified JWT, and the Rust data plane independently rejects any (identity, mount) pair whose tenant IDs do not match.

## What it is (the concept)

A **trust boundary** is a logical line in a system where the level of trust accorded to data or principals changes. Code on the high-trust side of the boundary must never accept a claim made by code (or a caller) on the low-trust side without independent verification. In grobase this manifests as two distinct enforcement points: the **API gateway** (Kong), which governs what identity headers may reach any upstream service, and the **data plane** (Rust), which independently validates that the resolved identity is scoped to the same tenant as the database mount being operated on. A third invariant — the **single identity authority** principle — ensures that credential verification (Argon2id hashing) is performed exclusively in the Go control plane and never duplicated in Rust.

## What it defends against

See [Privilege Escalation via Trust-Boundary Crossing](../../attack/trust-boundary.md). In this application context the threat is a caller forging HTTP headers (`X-User-Id`, `X-Baas-Tenant-Id`, etc.) to impersonate another user or read/write another tenant's data, or submitting a (key, mount) pair whose tenant IDs disagree in order to perform a **confused-deputy** cross-tenant operation. Because grobase serves multiple isolated tenants over shared infrastructure, a gap at either boundary would allow horizontal privilege escalation across the entire multi-tenant surface.

## How grobase implements it

### 1 — Edge header sanitisation (Kong pre-function)

[`infra/docker/services/kong/conf/kong.yml`](../../../../apps/grobase/infra/docker/services/kong/conf/kong.yml) — a global `pre-function` plugin runs on every request before any route handler:

```lua
kong.service.request.clear_header("X-User-Id")
kong.service.request.clear_header("X-User-Email")
kong.service.request.clear_header("X-User-Role")
local _p = kong.request.get_path()
if _p and (_p:sub(1, 11) == "/functions/" or _p:sub(1, 7) == "/query/") then
  kong.service.request.clear_header("X-Baas-Tenant-Id")
  kong.service.request.clear_header("X-Baas-User-Id")
  kong.service.request.clear_header("X-Tenant-Id")
end
```

After clearing, the plugin base64-decodes the JWT payload (whose signature Kong has already verified via its `jwt` plugin) and sets `X-User-Id`/`X-User-Email`/`X-User-Role` exclusively from `claims.sub`/`claims.email`/`claims.role`. A request with no valid bearer token therefore arrives at every upstream with those headers absent. The Lua sandbox is restricted to `cjson.safe` via `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES` in [`orchestrators/compose/base/gateway.yml`](../../../../apps/grobase/orchestrators/compose/base/gateway.yml) (line 59), limiting what the pre-function script may `require`.

The in-config comment names the exact forgery vector it closes: the `/functions/` runtime namespaces by the first of `X-Baas-Tenant-Id`/`X-Baas-User-Id`/`X-Tenant-Id`/`X-User-Id`, so a forged `*-Tenant-Id` would read or deploy another tenant's functions; the `/query/` legacy TS query-router defaults to compat-identity mode and trusts a raw `X-Baas-Tenant-Id` — the forgeable header is gone before it reaches that service.

### 2 — Data-plane identity/mount guard (Rust)

[`src/data-plane-router/crates/data-plane-server/src/routes/helpers.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/helpers.rs) — `validate_identity_mount` is the standard gate through which every schema, transaction, and operation handler passes:

```rust
pub(super) fn validate_identity_mount(
    state: &AppState,
    identity: &RequestIdentity,
    mount: &DatabaseMount,
) -> Result<(), String> {
    if !identity.is_tenant_scoped() {
        return Err("identity.tenant_id is required".to_string());
    }
    if identity.tenant_id != mount.tenant_id {
        return Err("identity tenant does not match mount tenant".to_string());
    }
    // ...engine presence check...
    Ok(())
}
```

It rejects the request if the identity carries no `tenant_id` (not tenant-scoped), if `identity.tenant_id != mount.tenant_id` (cross-tenant mismatch), or if the mount's engine is not registered in the Rust router. This check is independent of the Kong layer — a request that somehow bypassed Kong header-stripping would still be stopped here.

### 3 — Single identity authority: Go owns Argon2id, Rust never hashes

[`src/data-plane-router/crates/data-plane-server/src/auth.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/auth.rs) — the module doc states the invariant explicitly:

> "Go remains the SOLE identity authority: Rust never hashes or stores API keys."

`verify_key` (line 70) POSTs the cleartext `X-Baas-Api-Key` to the Go control plane's `POST /v1/keys/verify` via an internal service token (either HMAC-signed or bearer, line 84–91). It trusts only `valid: true` + `tenant_id` in the response; the Argon2id comparison stays in Go.

[`src/control-plane/internal/tenants/keys_verify.go`](../../../../apps/grobase/src/control-plane/internal/tenants/keys_verify.go) — `VerifyKey` selects non-revoked candidates by `key_prefix`, performs a **constant-time hash comparison** via `s.hasher.verifyKeyHash` (line 93), stamps `last_used_at` asynchronously, and lazily upgrades legacy Argon2id hashes (line 97–99). The DSN for the mount is resolved separately via the adapter-registry (`GET /databases/{id}/connect`) and never transits a client.

## How we know it is applied

**Kong pre-function:** the `pre-function` plugin is declared at the top-level `plugins:` key in `kong.yml` (lines 99–152), making it a **global plugin** that applies to every route without per-service opt-in. The `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: "cjson.safe"` env var is live on the Kong container as defined in `gateway.yml` line 59. The in-config comment at line 103–106 documents the exact impersonation scenario:

```
-- Without this, a request on the anonymous path (or with no/invalid bearer)
-- could forge X-User-* and impersonate a user at any compat-mode upstream.
```

**Data-plane guard:** `validate_identity_mount` is called by the schema/transaction/operation route handlers as the standard gating function, documented at `helpers.rs` lines 162–167 ("NOT admin-gated: any authenticated identity that passes `validate_identity_mount` may read its OWN mount's schema — same gating as `begin_transaction`"). It is exercised by the Rust workspace tests (`make rust-data-plane-test` = `cargo test --workspace`).

**Identity authority:** `bypass_auth.rs` calls `crate::auth::verify_key` on every request reaching the direct `/data/v1` front door (when `DATA_PLANE_BYPASS_ENABLED=1`). `keys_verify.go` is covered by `go test ./...` in CI and by `keys_security_test.go` / `jwt_test.go` in the `tenants` package.

## Reference

The OWASP Threat Modeling Cheat Sheet ([https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html)) defines trust boundary analysis as a primary decomposition activity: enumerate each point where data crosses from lower to higher trust and verify that the receiving side cannot be misled by claims the lower-trust side provides. Grobase's three-layer approach — edge sanitisation, plane-level tenant matching, and centralised credential authority — directly implements this as a defence-in-depth chain rather than a single perimeter.

## Residual risk / assumptions

- **Internal service token exposure:** `verify_key` and the adapter-registry call both require a valid service token (`X-Service-Token` or HMAC `X-Service-Auth`). If that token is leaked (e.g., via a container environment variable dump), an attacker inside the Docker network could call `POST /v1/keys/verify` directly with any cleartext key.
- **Kong admin port:** the Kong Admin API (`8001`) must not be publicly reachable — a caller who can reconfigure Kong can remove the global pre-function plugin. Gate `m157` (`kong-admin-not-exposed`) verifies this separately.
- **JWT algorithm confusion:** the Kong `jwt` plugin verifies the signature before the pre-function runs, but relies on the algorithm declared in the token header matched against the configured secret. Key-confusion attacks (RS256 vs HS256) are the Kong plugin's responsibility, not the pre-function's.
- **`DATA_PLANE_BYPASS_ENABLED=0` by default:** the direct Rust `/data/v1` front door is shadow-only by default; when disabled, `verify_key` in `auth.rs` is not reachable and the trust boundary for that path collapses to the existing Kong + Go query-router chain. Enabling the bypass without validating the HMAC service-auth path widens the authority boundary.
- **No cross-plane revocation propagation:** key revocation in Go (`revoked_at IS NULL` filter in `verifyKeySQL`) is not pushed to the Rust verify-cache TTL. A revoked key remains usable for the cache TTL window (hot path only) before being rechecked.
