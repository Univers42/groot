# Session Management — osionos (the block editor)

> The osionos block editor enforces three mutually-reinforcing session controls: the `osionos_v1.` app-session token is treated as opaque on the client (no HMAC verification), the one-time URL handoff token is erased from browser history immediately after a single server-side exchange, and every fresh login replaces — never inherits — a prior user's persisted session.

---

## What it is (the concept)

**Session management** is the lifecycle of an authenticated context: how a **session token** is issued, transported, stored, expired, and destroyed. A correct implementation ensures that tokens cannot be stolen from the URL bar or browser history (**session token leakage**), that a fresh login cannot adopt a prior user's context (**session fixation**), and that old sessions do not persist indefinitely (**stale session accumulation**). The key vocabulary here is: **opaque token** (a value the client carries but is not trusted to interpret authoritatively), **one-time handoff** (a token valid for exactly one server-side exchange), and **TTL** (a wall-clock expiry that bounds how long a record may linger in storage).

---

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md).

In the osionos context the concrete threats are:

1. **Handoff-token leakage** — the `bridge_token` query parameter appears in the URL at the moment of redirect from the marketing site. Without active scrubbing it would persist in browser history, the address bar, and the `Referer` header of any subsequent navigation — making it available to a shoulder-surfer, a browser extension, or a same-origin analytics call.
2. **Session fixation on shared browsers** — without a strict replace-by-default rule, a new user signing in on a machine where a colleague was already authenticated could silently inherit that colleague's workspace context.
3. **Stale cross-account sessions in the account switcher** — bridge session records stored in `localStorage` without an expiry would remain selectable indefinitely even after the underlying server token was invalidated.

---

## How osionos implements it

### 1. One-time handoff token consumption and URL scrubbing

`apps/osionos/app/src/features/auth/model/userStore.helpers.ts`

`consumeBridgeSessionFromLocation` (lines 120–133) reads the `bridge_token` value from either the query string or the URL hash, exchanges it with the bridge server via a single `POST /api/auth/bridge/consume` with `credentials: 'include'`, and then — immediately on success, before any state is committed — calls `clearBridgeTokenFromLocation` (lines 110–118):

```typescript
export function clearBridgeTokenFromLocation() {
  const url = new URL(globalThis.location.href);
  url.searchParams.delete('bridge_token');
  const hashParams = new URLSearchParams(/* hash */);
  hashParams.delete('bridge_token');
  url.hash = hashParams.toString();
  globalThis.history.replaceState(globalThis.history.state, document.title, url.toString());
}
```

`history.replaceState` rewrites the current history entry in-place so neither the token nor a clean-URL successor appear as two separate entries navigable with the back button.

### 2. Opaque app-session token — client reads claims, never verifies signature

`apps/osionos/app/src/features/auth/model/userStore.helpers.ts`

`decodeBridgeAppTokenPayload` (lines 55–69) base64-decodes the `osionos_v1.<payload>.<signature>` token's middle segment using `atob` and `JSON.parse`. It does **not** recompute or compare the HMAC — the secret is exclusively server-side. The `is_admin` claim and the `exp` field derived from this decode are used only for UI gating:

```typescript
/** …false for non-bridge or expired tokens. */
export function isAdminFromSessionToken(token: string | null | undefined): boolean {
  if (isBridgeAppTokenExpired(token)) return false;
  return decodeBridgeAppTokenPayload(token)?.is_admin === true;
}
```

The inline comment states the flag is "derived (not stored separately) so it can't drift from the session" — the server is authoritative; a client-forged claim in the payload reaches no API call with enforcement power.

### 3. Replace-by-default session isolation and 7-day TTL expiry

`apps/osionos/app/src/features/auth/model/sessionSelect.ts`

`selectActivatedSessions` (lines 28–40) is the single decision point for which persisted sessions to activate on initialisation. When a fresh website handoff arrives (`fromUserId` is set), it builds the activation set from an **empty base** — the prior user's record is excluded — unless the user had deliberately set the one-shot `ADDING_ACCOUNT_FLAG` in `sessionStorage` before redirecting:

```typescript
if (fromUserId && fromRecord) {
  const base: Record<string, T> = adding ? { ...persisted } : {};
  base[fromUserId] = fromRecord;
  return Object.values(base);
}
```

`apps/osionos/app/src/features/auth/model/useUserStore.ts`

`BRIDGE_SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000` (line 53). `readPersistedBridgeSessions` (lines 123–146) drops any record whose `expiresAt` is in the past before returning the map, and also rejects records missing a valid `session.userId` and `persona.id`. Records that survive through `activateBridgeSessions` (lines 208–245) are re-persisted with a guaranteed `expiresAt`, closing the path by which a legacy record without an expiry field could accumulate.

---

## How we know it is applied

**Unit test suite — `tests/canvas/session-select.test.ts`** (5 tests, all asserting the isolation invariant directly):

```
test("fresh handoff REPLACES — a new sign-in never inherits the prior user's session", () => {
  const persisted = { "user-a": A };
  const records = selectActivatedSessions("user-b", B, persisted, /* adding */ false);
  assert.deepEqual(records.map((r) => r.session.userId), ["user-b"]);
  assert.ok(!records.some((r) => r.session.userId === "user-a"));
});
```

This test is part of the `npm run test:canvas` gate (`node --test`, service `playground`), which runs inside Docker and is required to pass before merge. The test directly exercises `selectActivatedSessions` with a persisted record for a different user and asserts that user is absent from the activated set — the exact cross-account leakage vector the control defends against.

The URL scrub is exercised structurally: `consumeBridgeSessionFromLocation` calls `clearBridgeTokenFromLocation()` unconditionally after a successful response (line 131 of `userStore.helpers.ts`), so the scrub fires on every bridge-session import path regardless of which component initiates it.

---

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) prescribes that session tokens must never persist in URLs after exchange and that new sessions must never inherit context from a previous user on the same client. The osionos implementation addresses both prescriptions through the `history.replaceState` scrub and the `selectActivatedSessions` replace-by-default rule, respectively.

---

## Residual risk / assumptions

- **Server-side token revocation is outside scope of this client.** If the bridge server does not revoke the `osionos_v1.` token after the first `/api/auth/bridge/consume` call, a race-window replay (e.g., from a network log) remains possible. This control only removes the token from the client-visible URL.
- **`localStorage` is not encrypted.** Persisted bridge sessions (including the opaque access token) sit in `localStorage` in plaintext. Any XSS that reaches `document` context can read them. The TTL expiry reduces the attack window but does not eliminate it.
- **The `is_admin` client flag is UI-only.** API endpoints enforcing admin-level operations must re-verify the token server-side. A bug that wires a UI path directly to a client claim without a server round-trip would bypass this control.
- **`ADDING_ACCOUNT_FLAG` lives in `sessionStorage`.** A tab opened via `window.open` with `noopener` gets a fresh `sessionStorage`, so the deliberate merge intent cannot survive cross-origin redirect in that case; the user would have to re-initiate the "add account" flow.
- **The 7-day TTL assumes the server token lifetime is shorter.** If the upstream gotrue JWT or bridge app-session token is valid for longer than 7 days, the client TTL provides the only expiry gate for the persisted record.
