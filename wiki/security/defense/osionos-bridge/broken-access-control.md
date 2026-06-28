# Broken Access Control — osionos-bridge (website-to-editor trust boundary)

> The bridge re-implements tenant isolation in application code so that no authenticated user can read or mutate a workspace or page outside their verified membership scope, compensating for the RLS-bypassing service-role key it holds.

## What it is (the concept)

**Broken Access Control** describes any condition in which a system fails to enforce that authenticated principals can only act on resources they are authorized to reach. The canonical OWASP form includes **Insecure Direct Object Reference (IDOR)** — guessing or iterating an identifier to access another tenant's record — and **privilege escalation**, where a lower-privileged role performs operations reserved for higher ones. Correct mitigation requires that every request be re-authorized against the caller's verified identity and role, not merely against the presence of a valid session token. The authorization check must be **mandatory and consistent** across every handler that touches protected resources.

## What it defends against

See [Unauthorized Access / Privilege Escalation](../../attack/broken-access-control.md).

In the osionos-bridge context the threat is acute because the bridge holds the **BaaS service-role key** (configured via `KONG_SERVICE_API_KEY`), which bypasses PostgREST Row Level Security entirely. Any request the bridge forwards to the BaaS will succeed at the database layer regardless of the originating user. Without an explicit application-level membership check, one tenant's session token could be used to list, search, or mutate another tenant's workspaces and pages. The bridge therefore re-implements the isolation that RLS would otherwise provide.

## How osionos-bridge implements it

Two complementary mechanisms are in place.

**Per-route workspace and page authorization (`bridge-api.mjs`)**

`requireWorkspaceAccess` ([`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs), lines 761-792) is the primary gate. It operates in two paths:

1. If the requested `workspaceId` is already in the bearer token's `workspaceIds` claim, it fetches the caller's workspace list via `listSessionWorkspaces` and calls `memberHasPermission` (lines 720-726) against the required permission. `memberHasPermission` grants access only to `owner`/`admin` roles or to members whose `permissions` array contains the specific required permission (e.g. `'read'`, `'update'`, `'delete'`). Any miss throws a `403`.
2. If the `workspaceId` is absent from the token's scope (org/teamspace membership is not embedded in the token), it falls back to a live query of `osionos_workspace_members` for that `(userId, workspaceId)` pair. A missing or permission-insufficient row throws `403` immediately.

```js
// bridge-api.mjs line 764, 769-770
if (!authContext.workspaceIds.includes(normalizedWorkspaceId)) {
    const member = await workspaceMemberRow(authContext.userId, normalizedWorkspaceId, config, fetchImpl).catch(() => null);
    if (!member || !memberHasPermission(member, normalizePermission(permission))) {
        throw Object.assign(new Error('App session is not scoped to this workspace.'), { status: 403 });
    }
```

`requirePageOwnership` (lines 736-747) adds a **page-level defense-in-depth layer** on top: a page may be mutated only by its `owner_id`, a workspace `owner`/`admin`, a member with the `'update'` permission, or an explicit page collaborator with `editor`/`owner` role. Any other caller hits the `403` throw at line 746.

`ownerOrWorkspaceAccess` (lines 824-829) covers a narrower case: the server-stamped `owner_id` on a record allows the owning user to reach their own row even when the workspace-membership gate would otherwise deny (e.g. a seed workspace they reach only via a MOUNT). Because `owner_id` is written server-side it never widens cross-user access.

**LiveKit RTC token authorization (`bridge-rtc.mjs`)**

`authorizeRtcJoin` ([`apps/osionos/app/scripts/bridge-rtc.mjs`](../../../../apps/osionos/app/scripts/bridge-rtc.mjs), lines 144-169) is the **single ABAC hook** before any media grant is minted. It resolves the channel's workspace (from `osionos_channels` when the chat workstream is active, else the requested or session workspace), then requires a matching row in `osionos_workspace_members` for the calling user. A missing row throws `httpError(..., 403)`.

```js
// bridge-rtc.mjs lines 160-163
const members = await baasRestGet(config, fetchImpl,
    `osionos_workspace_members?workspace_id=eq.${targetWorkspaceId}&user_id=eq.${userId}&select=role,permissions&limit=1`);
const member = Array.isArray(members) ? members[0] : null;
if (!member) throw httpError('You are not a member of this channel’s workspace.', 403);
```

Only after `authorizeRtcJoin` returns successfully does `handleRtcTokenPost` (lines 210-248) call `mintLivekitToken`. The token TTL is clamped via `MAX_TOKEN_TTL_SECONDS = 6 * 60 * 60` (line 49) and the env-configurable `LIVEKIT_TOKEN_TTL_SECONDS`, with a hard floor of 60 seconds, preventing unbounded-lifetime grants.

## How we know it is applied

`requireWorkspaceAccess` is not dormant. It is invoked unconditionally at the top of every live list and search handler before any BaaS query runs:

- `handlePageList` — [`bridge-api.mjs` line 1530](../../../../apps/osionos/app/scripts/bridge-api.mjs): `await requireWorkspaceAccess(request, workspaceId, 'read', config, fetchImpl);`
- `handlePageSearch` — [`bridge-api.mjs` line 1566](../../../../apps/osionos/app/scripts/bridge-api.mjs): `await requireWorkspaceAccess(request, workspaceId, 'read', config, fetchImpl);`

The RTC handler is registered inside `createBridgeServer` at line 2625 and dispatched at line 2586:

```js
// bridge-api.mjs line 2625 (registration)
rtc: createRtcTokenHandler({ config, verifySession: verifyAppSessionToken, fetchImpl }),

// bridge-api.mjs line 2586 (dispatch — every request)
if (await context.social.rtc(url, request, response, context.config)) return;
```

The test suite at [`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs) (lines 262-299, `'requires both token scope and scoped BaaS workspace membership'`) exercises two live deny paths against the real implementation: an unscoped workspace rejects with `/not scoped/` and a viewer attempting a `'delete'` operation rejects with `/permission denied/`. These are not mocked stubs — the test invokes the exported `requireWorkspaceAccess` function directly with a fabricated fetch mock.

## Reference

[A01 Broken Access Control — OWASP Top 10:2021](https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/) identifies access control failures as the top web application risk category, encompassing IDOR, privilege escalation, and metadata tampering. The osionos-bridge implementation directly addresses the service-account IDOR variant: because a single elevated credential (the service-role key) proxies all tenant data, the bridge must enforce per-request, per-user membership checks that the database layer cannot provide on its own.

## Residual risk / assumptions

- The service-role key (`KONG_SERVICE_API_KEY`) is read from the environment at startup. If it leaks, an attacker can query PostgREST directly, bypassing the bridge entirely — RLS is not a backstop here. Key rotation and secret-manager delivery (vault42) are the mitigating controls outside this code.
- `requirePageOwnership` runs only when the page's `owner_id` is set; legacy or unowned pages (`owner_id IS NULL`) fall through to the workspace gate alone (see the `if (!isPublished && existing.owner_id == null) return;` early return at line 739). Published apps with a null `owner_id` are an explicit exception that the comment at line 739 flags.
- `authorizeRtcJoin` resolves the workspace from `osionos_channels` only when that table exists; until the chat workstream is deployed it falls back to the session's first `workspaceId`. A misconfigured or replayed `workspaceId` in the request body could therefore influence which workspace is checked for membership — callers must be treated as untrusted.
- There are no automated CI gates (e.g. `make baas-verify-m*` scripts) specifically asserting coverage of `requireWorkspaceAccess` invocations across all handlers. New handlers added without calling `requireWorkspaceAccess` would not be caught by an existing gate.
