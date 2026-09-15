# Broken Access Control — grobase (the BaaS backend)

> grobase enforces access control at four independent layers — Kong gateway ACL/IP gating, a deny-first ABAC/RBAC policy engine with SQL parity, server-controlled owner-scoping on every mutating operation, and flag-gated admin surfaces — so that no single misconfiguration grants unauthorised access.

## What it is (the concept)

**Broken Access Control** (OWASP A01:2021) occurs when an application fails to enforce the restrictions that determine which authenticated identities may read, modify, or administer which resources. The vulnerability class encompasses **horizontal privilege escalation** (accessing another user's data at the same privilege level), **vertical privilege escalation** (performing operations reserved for a higher role), and **IDOR** (Insecure Direct Object Reference, where a caller manipulates an identifier to reach a record they do not own). Correct access control requires that **authorization decisions are made server-side**, are **consistent across every code path**, and **default to deny** when no explicit grant exists.

## What it defends against

See [Unauthorized Access / Privilege Escalation](../../attack/broken-access-control.md).

In grobase's multi-tenant BaaS context the threats are concrete: a tenant using the public `anon` key to enumerate other tenants' database mounts via the adapter-registry; a caller forging an `owner_id` payload field to write or delete another user's rows; a low-privilege API key invoking raw SQL execution or credential rotation; and a policy engine that grants access by default when no matching rule is found. Each of these maps to a specific OWASP A01 failure mode.

## How grobase implements it

### 1. Kong gateway — ACL and IP restriction on admin surfaces

[`apps/grobase/infra/docker/services/kong/conf/kong.yml`](../../../../apps/grobase/infra/docker/services/kong/conf/kong.yml) declares every admin and control-plane route with layered plugins. The adapter-registry admin surface illustrates both controls:

```yaml
# consumer service_role is the only member of baas-admin (lines 15–19)
acls:
  - group: baas-admin
# admin-adapters route (lines 750–756)
- name: acl
  config:
    allow: [baas-admin]
    hide_groups_header: true
- name: ip-restriction
  config:
    allow: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.1]
```

The `anon` consumer is not in `baas-admin`, so a request carrying the public anon key resolves to a 403 before reaching the upstream. The same `ip-restriction` allow-list is applied to every admin route (`admin-meta`, `admin-provision`, `admin-tenants`, `admin-keys`, `admin-webhooks`, `admin-studio`, and the migrate/rotate handlers), confining the entire privileged surface to private and loopback ranges.

### 2. Deny-first ABAC/RBAC policy engine (Rust evaluator + SQL parity)

[`apps/grobase/src/data-plane-router/crates/data-plane-server/src/abac.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/abac.rs) implements the policy decision point. `Evaluator::decide` (L170–253):

1. Filters `user_roles` to those where `expires_at > now` or `expires_at` is `None`.
2. Returns `DENY` immediately when no active role exists.
3. Matches policies on `(resource_type, resource_name, action)` using exact or wildcard (`*`).
4. Sorts matched policies by `priority DESC`, then `effect ASC` (deny = 0 before allow = 1).
5. Returns `DENY` on the first matched deny; `ALLOW` on the first matched allow; `DENY` if no match.

The field-masking extension (`resolve_field_mask`, L277–306; `apply_field_mask`, L120–137) lifts per-field `hide`/`redact` directives from the policy JSONB conditions and removes or replaces column values in result rows before they leave the data plane.

The identical algorithm is implemented in SQL as [`public.has_permission`](../../../../apps/grobase/scripts/migrations/postgresql/007_permissions_system.sql) (L192–230), so the data plane can decide locally:

```sql
ORDER BY rp.priority DESC, rp.effect ASC  -- deny-first at same priority (L211)
IF pol.effect = 'deny' THEN               -- any deny wins (L214)
```

The `resource_policies` table enforces `CHECK (effect IN ('allow', 'deny'))` and enables RLS on all permission tables.

### 3. Server-controlled owner-scoping on every mutating operation

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/crud_build.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/crud_build.rs) strips `owner_id` from every client-supplied data map before building SQL:

```rust
// writable_columns (L37–45)
.filter(|(k, _)| k.as_str() != "owner_id")
```

`owner_predicate` (L49–61) appends `AND owner_id = $n` to every `UPDATE` and `DELETE`. For `UPSERT`, `owner_id` is placed in the `ON CONFLICT` target so conflict arbitration is tenant-local and the field is immutable on conflict (it is injected as a server value and excluded from the `SET` clause, L183–185).

The single source of truth for the owner value is [`owner_principal()`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-core/src/identity.rs) (L49–51):

```rust
pub fn owner_principal(&self) -> &str {
    self.user_id.as_deref().unwrap_or(self.tenant_id.as_str())
}
```

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs) passes the scoped flag to `run_insert`/`run_upsert` and `read_scoped` to `run_update`/`run_delete` on every dispatch (`derive_scope`, L179–183).

### 4. Admin owner-scope bypass — OFF by default; writes still stamp owner

[`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/adapter.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/adapter.rs) reads `DATA_PLANE_ADMIN_BYPASS` once at pool open (L119–122); the default is `false`. Even when the flag is enabled, `INSERT` and `UPSERT` continue to stamp `owner_id` — only `UPDATE`/`DELETE` drop the `AND owner_id = $n` predicate for admin callers. The `tx.rs` unit test `derive_scope_off_is_byte_parity` (L284) asserts that the default-off path is structurally identical to no bypass existing.

### 5. Privileged data-plane surfaces gated by `require_admin`

Every handler under `/v1/admin/*` in [`apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/admin.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/admin.rs) calls `require_admin` as its first statement:

```rust
// execute_raw_admin (L57), apply_migration_admin (L96),
// rotate_credential_admin (L158), evict_verify_admin (L200)
if let Err(resp) = require_admin(&request.identity, "/v1/admin/raw") {
    return resp;
}
```

`require_admin` in [`routes/helpers.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/helpers.rs) (L311–323) returns a uniform 403 `forbidden` unless the identity carries role `service_role`/`admin` or scope `admin`. No handler is reachable before this check.

### 6. Bypass front-door flag-gated OFF; scope-checked when enabled

The direct `/data/v1/{query,schema,graph}` surface is only mounted when `DATA_PLANE_BYPASS_ENABLED` is truthy ([`config.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/config.rs) L93–94, default `"false"`; [`routes/mod.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/mod.rs) L91). When enabled, [`bypass_auth.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/bypass_auth.rs) enforces scope with `require_scope` (L28–34: `admin` satisfies any; otherwise the exact `read`/`write` scope is required), logs audited `scope_denied` events (L174–191), enforces a per-tenant token-bucket rate limit logging `rate_limited` (L198–218), and refuses to start without `INTERNAL_SERVICE_TOKEN` (503, L72–78).

### 7. Package/tier capability gating

[`apps/grobase/src/control-plane/internal/adapterregistry/connection.go`](../../../../apps/grobase/src/control-plane/internal/adapterregistry/connection.go) calls `stampPackage` on every `GetConnection` (L172–175), embedding the tenant's tier mask into `CapabilityOverrides`. The data plane then maps a capability-gated operation to `403 capability_gated` ([`helpers.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/helpers.rs) L108–111) and a quota breach to `402 quota_exceeded` (L258–267).

## How we know it is applied

**CI gates** (`.github/workflows/ci.yml`):

- L650: `cargo test --workspace` — runs all Rust unit tests, including `abac.rs` (`deny_beats_allow_at_higher_priority`, `no_role_no_access`, `expired_role_is_inactive`, `action_not_in_policy_denies`), `crud_build.rs` (`update_strips_owner_id_and_scopes_to_owner`, `upsert_forces_owner_into_conflict_target`), `tx.rs` (`derive_scope_off_is_byte_parity`, `derive_scope_admin_bypass_drops_read_scope_only`), and `bypass_auth.rs` scope/ratelimit tests.
- L641: `go test ./...` — covers Go control-plane including `stampPackage`.
- L578: `go test ./internal/packages/` — tier-gating unit tests.

**Milestone verify scripts** (all live-stack probes):

- [`scripts/verify/m9-abac.sh`](../../../../apps/grobase/scripts/verify/m9-abac.sh) — ABAC policy evaluation gate.
- [`scripts/verify/m135-abac-column-mask.sh`](../../../../apps/grobase/scripts/verify/m135-abac-column-mask.sh) — column-level hide/redact mask verification.
- [`scripts/verify/m158-admin-tenant-scope.sh`](../../../../apps/grobase/scripts/verify/m158-admin-tenant-scope.sh) — pins the Kong ACL fix: anon key → 403 on `/admin/v1/databases`.

The Kong ACL and IP-restriction plugins are declared inline in the live-mounted `kong.yml`; they are active on every container start with no further configuration step.

## Reference

OWASP A01 Broken Access Control — OWASP Top 10:2021: <https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/>

The OWASP guidance characterises broken access control as the most prevalent web application risk, covering both missing enforcement and incorrect default-to-allow posture. grobase's layered approach addresses both failure modes: the ABAC engine and `owner_predicate` default to deny, while the Kong ACL and `require_admin` guard make admin surfaces unreachable from the public network even if a bug were introduced in an individual handler.

## Residual risk / assumptions

- **JWT trust boundary**: the data plane trusts the identity parsed from the JWT delivered by Kong. If Kong's JWT secret (`GOTRUE_JWT_SECRET` / the service-role key) is compromised, all authorization decisions are void. The secret is managed via vault42 and is never echoed to callers.
- **`DATA_PLANE_ADMIN_BYPASS` mis-deployment**: enabling this flag in a production container without operator intent removes owner-scoping from `UPDATE`/`DELETE` for admin identities. It is not validated against an allowlist of environments.
- **ABAC covers the Postgres adapter**: MySQL and MongoDB adapters mirror the owner-stamping logic, but their parity with the Rust ABAC evaluator is maintained by convention, not by a shared FFI boundary. Drift is possible.
- **IP restriction is network-layer only**: `ip-restriction` in Kong is enforced at the proxy; a compromised container on the `mini-baas` Docker network could reach admin routes directly without passing through Kong.
- **Column-level masking is data-plane only**: the `apply_field_mask` path runs in the Rust data plane. If a tenant bypasses the data plane and queries the database directly (e.g., via a misconfigured Postgres firewall rule), ABAC masks do not apply — RLS policies in the database are the final line of defence for that case.
