# 0026. A page outside the caller's workspaces answers like a missing id

- Status: accepted (osionos `fix/page-read-not-found`); not deployed
- Date: 2026-10-22
- Deciders: owner, after a devil ruling (2026-10-22: PROCEED-WITH-CONDITIONS, C132-C137)

## Context

- `GET /api/pages/:id` answered 404 for a missing id and for another member's private page, but 403 for a
  page that exists in a workspace the caller is not a member of. `canReadPageRow` passes a shared or public
  row, or one listing the caller as collaborator, and the member gate refused it afterwards
  (`readablePageAccess`). Anyone with a session could probe ids: a 403 meant the page exists.
- The same split held on PATCH, DELETE and favorites (`ownerOrWorkspaceAccess`) and on the page-scoped
  routes (`requirePageScopeAccess`: config, actions, translate, marketplace template). The comment on
  `requirePageScopeAccess` already promised them the missing-page path.
- Found while fixing backlinks for C101 (osionos `3935d600`).
- The client evicted every page whose content fetch answered 404 (`fetchPageContent`). Once a removed member
  gets 404, a page holding an edit the outbox has not published yet would leave the store, and the edit with
  it, without a word. The outbox already handles PATCH 403 and 404 the same way (refused-edit recovery).

## Decision

1. Client first (C132). A content fetch's 404 evicts only a clean page (`isPageClean`: stamp equals the
   ledger, or the viewer may not publish). A page with an unpublished edit is left to the outbox. When the
   evicted page is the open one, its tab closes with one warning toast; a background fetch (search, export)
   evicts quietly, so stale cached pages do not raise a toast each.
2. Bridge (C134-C136). A non-owner with no members row in the page's workspace gets the same
   `404 Page not found.` as a missing id, in `readablePageAccess`, `ownerOrWorkspaceAccess` and
   `requirePageScopeAccess`; the last now takes its missing-page path, scoped to the caller's own workspace.
   A member who lacks the route's permission is still told 403.
3. Deploy order (C133). The client (Vercel) ships before the bridge image that carries 2.

## Consequences

- `tests/bridge/bridge-page-not-found.test.mjs`: 9 routes x 6 hidden cases (shared, stale token, public,
  collaborator, another workspace, just removed) answer with the status and body of a missing id, and
  `GET /api/pages/:id` makes the same number of BaaS calls for both. 54 of its 60 cases failed before the fix.
- Flipped from 403 to 404: 8 assertions in `bridge-membership-read` (the C137 list) and 1 in
  `bridge-workspace-gate`: a token that lists the workspace but no members row. That one was outside C137's
  list; the rule is the same. Still 403: a member without the permission (membership-read's publish downgrade
  and read-permission cases, marketplace-template, page-sharing).
- Caveat: write routes and page-scoped routes make one more BaaS call for a hidden page (the members lookup)
  than for a missing id. The two differ in timing, not in status or body.
- The IDE file transport now reads a hidden page as not found instead of permission denied
  (`bridgeTransport.ts:53`).
- Not changed: an edit refused on a page the viewer can no longer read is still discarded, with an error
  toast (refused-edit recovery, "unreadable" branch). Copying it to the viewer's private workspace would keep
  content of a workspace they were removed from. That is a policy decision for its own ruling.
