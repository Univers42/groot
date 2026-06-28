# Broken Access Control — osionos (the block editor)

> Every chat media asset is retrieved exclusively through a bearer-authenticated fetch; unauthenticated browsers and non-members cannot load attachment bytes, because the serve route requires the page-scoped JWT that only an active workspace session holds.

## What it is (the concept)

**Broken access control** occurs when an application fails to enforce that a user can only act on resources they are legitimately authorised to access, allowing horizontal (same-privilege) or vertical (privilege escalation) boundary violations. In the OWASP model, this includes both **direct object reference** flaws — where a URL alone is sufficient to retrieve a protected resource — and **missing function-level access control**, where UI affordances or API operations are not consistently gated by server-verified identity. Effective access control requires enforcement at every layer, from the HTTP transport down to the data store, with client-side gating acting only as a **depth-in-defense** supplement to authoritative server-side rules.

## What it defends against

See [Unauthorized Access / Privilege Escalation](../../attack/broken-access-control.md).

In osionos specifically, the threat is a cross-tenant or unauthenticated browser loading another channel's uploaded media by issuing a plain `<img src="…">` or `<audio src="…">` request: browsers send no custom headers for tag-sourced sub-resources, so a naive serve route would expose every stored asset to any unprivileged request. A second, lower-severity threat is a signed-in user rendering page management controls (edit, delete, move) for pages they do not own or collaborate on — leaking UI affordances even when the downstream API would reject the write.

## How osionos implements it

### 1. Membership-gated media retrieval (`useAuthedObjectUrl`)

[`src/widgets/channel-messages/ui/attachments/useAuthedObjectUrl.ts`](../../../../apps/osionos/app/src/widgets/channel-messages/ui/attachments/useAuthedObjectUrl.ts) is the single rendering path for all chat image, video, audio, and waveform attachments. The hook's inline comment documents the architectural rationale explicitly:

```
The chat serve route (GET /api/chat/uploads/:id) is membership-gated on the
Authorization bearer header — a plain `<img src>`/`<audio src>` cannot send it
(it would 401). So fetch the bytes once with the page-JWT and hand back a
`blob:` object URL (revoked on cleanup).
```

The implementation (lines 38–45) reads the active page JWT via `getActivePageJwt()`, attaches it as `Authorization: Bearer <token>`, and only on a successful `res.ok` response converts the response to a `URL.createObjectURL(blob)` — handing the consumer an ephemeral `blob:` URL that never exposes the upstream serve URL in the DOM. The cleanup function (line 52) calls `URL.revokeObjectURL(objectUrl)` on unmount.

Local draft previews (`blob:`/`data:` URIs produced by `URL.createObjectURL` before upload) are passed through unchanged — the `isLocalPreview` guard (line 26) prevents the authed-fetch path from running on an already-local resource.

[`src/widgets/channel-messages/ui/attachments/MessageAttachments.tsx`](../../../../apps/osionos/app/src/widgets/channel-messages/ui/attachments/MessageAttachments.tsx) is the consumer: the `MediaAttachment` component calls `useAuthedObjectUrl(attachment.url)` (line 47) and holds the result in `src`; if `src` is `undefined` (token absent, fetch failed, or 401 from the server), it renders only an animated skeleton placeholder — no bytes, no asset URL exposed. The hook is also wired into `WaveformPlayer` for audio attachments (line 76 dispatches `<WaveformPlayer>` for `attachment.type === 'audio'`).

### 2. Authenticated upload path (`attachmentApi`)

[`src/shared/chat/attachmentApi.ts`](../../../../apps/osionos/app/src/shared/chat/attachmentApi.ts) closes the symmetrical gap on write: `uploadAttachment` (lines 51–53) attaches the same `Authorization: Bearer <token>` header to the `POST /api/chat/uploads` raw-bytes request, so both the store and the retrieval paths require the page-scoped JWT. A missing or expired session causes the upload to fail at the bridge layer before any storage occurs.

### 3. Client-side page ACL gating (defense-in-depth)

[`src/shared/lib/auth/pageAccess.ts`](../../../../apps/osionos/app/src/shared/lib/auth/pageAccess.ts) derives a `PageAccessContext` from the active workspace session and exposes predicate functions consumed by page management UI:

- `canReadPage` (lines 134–149): requires `hasWorkspaceAccess` (workspace membership), then checks page visibility (`public`/`shared`/`private`) and collaborator list.
- `canEditPage` (lines 151–165): additionally requires the user is the page owner or holds an `editor`/`owner` collaborator role.
- `canDeletePage` (lines 167–172): delegates entirely to `canEditPage`.
- `canMovePage` (lines 181–198): adds a destination workspace membership check and prevents non-owners from moving a page into a private workspace.

The context is read reactively via `usePageAccessContext` (lines 95–101), which uses `useSyncExternalStore` subscribed to `globalThis.__playgroundUserStore` — the same decoupling seam used by the API client — so ACL predicates track live session state without prop-drilling.

## How we know it is applied

**For media gating:** `useAuthedObjectUrl` is the rendering path for every non-local chat attachment. The `MessageAttachments` component renders only `MediaAttachment`, `WaveformPlayer`, and `LinkPreviewCard` — each of which routes through `useAuthedObjectUrl` for the byte-fetch. There is no `<img src={attachment.url}>` or `<audio src={attachment.url}>` anywhere in the attachments subtree; the raw serve URL is structurally unreachable in the DOM. A consumer that omits `useAuthedObjectUrl` would render a persistent skeleton placeholder, making the omission immediately visible.

**For the upload path:** `attachmentApi.ts` inlines the token attachment inside the only code path that issues the upload `fetch`; there is no alternative upload function in the module.

**For page ACL:** The predicates are exported by `pageAccess.ts` and consumed by page-management UI features to gate visibility of edit/delete/move affordances. The context is wired to the live user store, so log-out or session expiry immediately collapses all granted predicates to `false`.

## Reference

[A01 Broken Access Control — OWASP Top 10:2021](https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/)

Access control is the most prevalent web application security failure, consistently rising to the top of the OWASP ranking because enforcing it correctly across every request — including sub-resource loads that browsers issue without custom headers — demands explicit architectural decisions rather than passive omission. The bearer-authenticated fetch pattern in osionos directly addresses the class of IDOR failures OWASP identifies as object-level access control bypass via direct URL reference.

## Residual risk / assumptions

- **Server-side enforcement is out of scope for this document.** The client-side controls documented here are meaningful only if the osionos-bridge and grobase BaaS actually validate the bearer token against channel/workspace membership on every `GET /api/chat/uploads/:id` and `POST /api/chat/uploads` request. The client cannot verify that gate is correctly implemented.
- **Page ACL predicates are client-only.** `canEditPage`, `canDeletePage`, and `canMovePage` hide UI affordances but do not prevent a motivated user from issuing the underlying API calls directly. Authoritative enforcement lives in the bridge (PostgREST RLS rules + the bridge permission layer). The client gating is explicitly labelled defense-in-depth with `confidence: low` in the discovery record.
- **`getActivePageJwt()` must return a valid, unexpired token.** If the session store is stale (e.g. tab was backgrounded and the token rotated without a re-auth), the fetch silently receives a 401 and renders no asset — the failure mode is a blank skeleton, not a data leak, but it degrades the UX. There is no automatic token-refresh retry inside `useAuthedObjectUrl`.
- **Blob URL lifetime.** The `blob:` URL handed to the renderer is valid only within the current tab's origin and lifetime. Cleanup on unmount (via `revokeObjectURL`) is wired in the hook's effect return; however, if a parent component holds a reference to the `blob:` URL beyond the hook's mount lifetime, the URL becomes invalid rather than re-pointing at new bytes.
- **`blob:`/`data:` passthrough is trusted.** Draft preview URLs are passed to consumers without an authentication check because they originate from a local `File` object (`URL.createObjectURL`) before upload. If a malicious attachment descriptor somehow reaches the message list with a `blob:` or `data:` value already set as `url`, it would bypass the gated-fetch path entirely. Mitigation depends on the bridge rejecting non-object-key URLs at ingestion time.
