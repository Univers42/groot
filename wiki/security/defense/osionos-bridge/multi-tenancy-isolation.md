# Multi-Tenancy Isolation — osionos-bridge (website-to-editor trust boundary)

> Every BaaS read and write issued by the bridge is constrained to the caller's verified workspace/user scope; no cross-tenant enumeration is possible even though the bridge holds a service-role key.

## What it is (the concept)

**Multi-tenancy isolation** is the property that a shared backend infrastructure enforces per-tenant data boundaries so that one tenant's authenticated session cannot read, write, or enumerate another tenant's data. It operates at the **query filter layer**, not just at the authentication layer: the access token proves identity, but tenant isolation proves _scope_. The critical mechanism is **query-level scoping** — every PostgREST filter carries a `workspace_id` or `user_id` derived from the verified session, making cross-tenant rows structurally unreachable rather than merely unauthorized.

## What it defends against

See [Cross-Tenant Data Leakage](../../attack/multi-tenancy-isolation.md).

The osionos-bridge holds the grobase BaaS service-role key (`SERVICE_ROLE_KEY` / `KONG_SERVICE_API_KEY` / `BAAS_SERVICE_ROLE_KEY`, resolved in that fallback order) and proxies PostgREST on behalf of the editor frontend. Without explicit query scoping, any authenticated user could craft a request that an unscoped service-role connection would satisfy across all tenants. In this application, the threat is specifically workspace enumeration (listing another org's databases, pages, or members) and cross-workspace write injection (persisting content into a workspace whose ID is guessed or leaked from a URL parameter).

## How osionos-bridge implements it

All evidence is in [`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs).

**UUID validation before interpolation.** The constant `UUID_REGEX` (line 76) is applied by `requireUuid()` (lines 233–237) to every caller-supplied workspace ID and page ID before it reaches a PostgREST query string. A non-UUID value yields an HTTP 422 immediately, preventing injection into filter expressions:

```js
function requireUuid(value, fieldName) {
    const normalized = safeText(value, 80);
    if (!UUID_REGEX.test(normalized)) throw Object.assign(new Error(`${fieldName} must be a UUID.`), { status: 422 });
    return normalized;
}
```

**Token-level workspace whitelist.** `verifyAppSessionToken()` (lines 415–429) parses the `osionos_v1.` HMAC token, validates `iss`/`aud`, confirms the `sub` (user ID) is a UUID, and strips any non-UUID entries from `workspace_ids` in the payload. If the filtered list is empty the request is rejected 401 — so the workspace scope is established from the cryptographically-verified token, not from query parameters.

**`requireWorkspaceAccess()` as the per-route gate.** Every workspace-scoped route calls `requireWorkspaceAccess()` (lines 761–779). It calls `requireUuid()` on the path parameter, then checks whether the normalized ID is present in the token's `workspaceIds`. If absent, it falls back to a live membership lookup against `osionos_workspace_members` (line 768, `workspaceMemberRow()`); any failure or missing row throws 403:

```
'App session is not scoped to this workspace.'  { status: 403 }
```

**Per-table filter in `workspaceMemberRow()`.** The helper (lines 750–758) applies both `workspace_id=eq.<workspaceId>` and `user_id=eq.<userId>` as PostgREST query filters — two columns, both derived from the verified session, not from caller input:

```js
const query = postgrestQuery({
    workspace_id: `eq.${workspaceId}`,
    user_id:      `eq.${userId}`,
    select: 'role,permissions',
    limit: '1',
});
```

**`listWorkspaceDatabases()` scopes to token-bound IDs only.** Lines 1854–1866 build the `workspace_id=in.(…)` filter from `workspaceIds` taken directly off the verified token (never from the HTTP request body), so database enumeration is bounded to workspaces the token declares:

```js
workspace_id: `in.(${workspaceIds.join(',')})`,
```

**`memberWorkspaceEntries()` is RPC-only, no synthesized access.** Lines 997–1025 contain the comment: _"a workspace appears here iff an `osionos_workspace_members` row exists"_. The function calls the `rpc/osionos_bridge_list_workspaces` stored procedure with `p_workspace_ids` taken from the membership table lookup — it never constructs or synthesises workspace IDs, so org/teamspace membership cannot be elevated client-side.

## How we know it is applied

The test suite in [`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs) exercises the live routes:

Line 360 — _"serves scoped workspace list and read routes from the bridge"_:

```js
it('serves scoped workspace list and read routes from the bridge', async () => {
    // ...
    const listResponse = await fetch(`${baseUrl}/api/workspaces`, { headers });
    assert.equal(listResponse.status, 200);
    const workspaces = await listResponse.json();
    assert.equal(workspaces[0]._id, workspaceId);   // only the session's workspace is returned
    assert.equal(workspaces[0].role, 'owner');
    // ...
```

The test constructs a real `BridgeServer` backed by a mock BaaS fetch, issues requests with an app-session Bearer token, and asserts that the workspace list contains exactly the workspace encoded in the token — confirming that the scoping logic is wired into the live route handler, not merely unit-tested in isolation.

## Reference

The [OWASP Multi-Tenant Application Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) defines the principle that tenant data boundaries must be enforced at the data access layer and not rely solely on UI-level access controls. The osionos-bridge implementation is consistent with that guidance: the PostgREST filter is the enforcement boundary, and the app-session token (not the HTTP session) is the authoritative source of scope — ensuring that even a stolen or replayed token cannot exceed the workspace IDs it was issued for.

OWASP Top 10 mapping: **A01:2021 — Broken Access Control**.

## Residual risk / assumptions

- **Token freshness.** The bridge verifies the HMAC and expiry of the `osionos_v1.` app-session token but does not call a revocation endpoint. A token compromised before its `exp` is valid for its remaining lifetime.
- **Service-role key scope.** PostgREST's Row-Level Security (RLS) policies in grobase are the final backstop. If RLS is misconfigured or disabled on a table, a service-role key bypasses it; the bridge's query filters are then the only tenant boundary. Correct RLS configuration in grobase is a prerequisite, not an assumption the bridge can verify at runtime.
- **`memberWorkspaceEntries()` failure mode.** The function catches all errors and returns `[]` (line 1022–1024). A BaaS availability event during session enrichment yields an empty shared-workspace list rather than an error, which is safe (under-permissive), but means the user may see a degraded workspace view without an explicit error signal.
- **Workspace ID source of truth is the token, not the DB.** If workspace IDs are minted or revoked without reissuing the app-session token (e.g., a workspace is deleted), the token continues to scope queries to the now-deleted workspace ID. PostgREST will return empty rows, but no explicit 403 is raised.
- **`bridge-chat`, `bridge-feed`, `bridge-rtc`, and other mounted modules** each own their own tenant-scoping logic (the bridge is modular per `apps/osionos/app/CLAUDE.md`). Isolation guarantees for those modules are not covered here and must be audited separately.
