# OAuth State Verification — mail and calendar (Google OAuth apps)

> Both bridge servers generate a cryptographically random state token before every Google
> authorization redirect, persist it server-side, and reject any OAuth callback that cannot
> produce a matching token — guaranteeing that only browser sessions originating on this server
> can complete a Google account binding.

## What it is (the concept)

**Cross-Site Request Forgery (CSRF)** in the OAuth 2.0 context is an attack in which a third
party crafts or replays an authorization callback URL to bind their own Google account (or an
intercepted authorization code) into a victim's session. The **`state` parameter** defined in
RFC 6749 §10.12 is the standard mitigation: a **nonce** generated per-authorization-attempt,
kept in server state, and verified on the callback before any token exchange occurs. The key
property is that the nonce must be **unguessable** (cryptographically random) and
**single-use** (consumed on first match, so replay is impossible).

## What it defends against

See [Cross-Site Request Forgery (CSRF)](../../attack/csrf.md).

In this application context the threat is OAuth login CSRF and authorization-code injection: an
attacker who obtains or forges a Google callback URL could redirect the victim's browser to that
URL, causing the bridge to exchange the code and store tokens tied to the attacker's Google
account instead of the victim's. Without state verification there is nothing to distinguish a
legitimate callback from a crafted one, because both arrive over ordinary HTTP redirects that
carry no inherent origin proof.

## How mail-calendar implements it

Both bridge servers apply an identical three-phase pattern.

**Phase 1 — state generation and persistence** (`startGmailAuth` / `startGoogleAuth`):

`apps/mail/bridge/server.mjs`, line 762-763:
```js
const state = randomBytes(24).toString('hex');
saveOauthState(state, googleRedirectUri);
```

`apps/calendar/bridge/server.mjs`, line 611-612:
```js
const state = randomBytes(24).toString('hex');
saveOauthState(state, googleRedirectUri);
```

`randomBytes(24)` produces 192 bits of OS-level entropy. `saveOauthState` (mail bridge, lines
229-233) writes `{ createdAt: Date.now(), redirectUri }` into a keyed state store after calling
`pruneStates` to evict expired entries; the token is included verbatim in the `state=` query
parameter of the Google authorize URL.

**Phase 2 — single-use consumption** (`consumeOauthState`, mail bridge lines 235-241):
```js
function consumeOauthState(state) {
  const states = pruneStates(readStates());
  const value = states[state];
  delete states[state];   // consumed: replay is rejected
  writeStates(states);
  return value || null;
}
```
The entry is deleted before returning, so each state token is valid for exactly one callback.

**Phase 3 — unconditional rejection before token exchange** (`finishGmailAuth` /
`finishGoogleAuth`):

`apps/mail/bridge/server.mjs`, lines 797-805:
```js
if (!code || !state || !oauthState) {
  html(response, 400, `
    <h1>Gmail authorization failed</h1>
    <p>Invalid or expired OAuth state.</p>
    ...
  `);
  return;
}
// exchangeToken is only reached when all three pass
```

`apps/calendar/bridge/server.mjs`, lines 641-648 mirrors this guard identically for the
Calendar flow. The `exchangeToken` call that redeems the authorization code at Google's token
endpoint is unreachable until `code`, `state`, and a live `oauthState` record are all present.

**Route wiring** — `handleAuthRoutes` (mail bridge line 846; calendar bridge line 692) maps:
- `GET /auth/gmail/start` (or `/auth/google/start`) → `startGmailAuth` / `startGoogleAuth`
  (writes state)
- any path in `callbackPaths` → `finishGmailAuth` / `finishGoogleAuth` (validates state)

This dispatcher is invoked unconditionally at lines 906 / 781 respectively, so every
authorization flow is covered.

## How we know it is applied

The rejection guard at `finishGmailAuth` line 797 (`if (!code || !state || !oauthState)`) is
structurally unconditional: it runs before `exchangeToken` regardless of any runtime flag or
environment variable. The `consumeOauthState` call on line 782 runs before the guard is even
evaluated, so an attacker who replays the same state value will find `oauthState === null` on
the second attempt.

Route registration at line 906 of the mail bridge (`if (await handleAuthRoutes(...)) return;`)
inside the top-level `createServer` request handler confirms the validator is live for every
inbound HTTP request, not gated by a feature flag.

The calendar bridge is structurally identical (line 781: `if (await handleAuthRoutes(...))
return;`), verified independently.

## Reference

[Cross-Site Request Forgery Prevention — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)

The OWASP cheat sheet dedicates a section to the OAuth `state` parameter as the correct
mechanism for CSRF protection in authorization flows, recommending cryptographically random,
unguessable values bound to the user session. The implementation here uses 24 bytes (192 bits)
of `crypto.randomBytes` entropy, which satisfies the "unguessable" requirement, and the
single-use `consumeOauthState` pattern satisfies the replay-prevention requirement the cheat
sheet identifies as mandatory.

## Residual risk / assumptions

- **State stored in process memory / local file**: `saveOauthState` writes to a local state
  store (not a distributed cache). If the bridge process restarts between the authorize redirect
  and the Google callback, all pending states are lost and the user must retry. This is a
  usability issue, not a security regression (the callback is rejected, not accepted).
- **No PKCE**: the bridges use the authorization-code flow without Proof Key for Code Exchange.
  PKCE would add a second layer of protection against code-injection in public-client scenarios,
  but these bridges run as confidential clients (server-side, with a `client_secret`), so the
  state parameter is the appropriate control per RFC 6749.
- **CSRF on non-OAuth endpoints**: the state mechanism covers only the OAuth authorize/callback
  round-trip. Any other state-mutating endpoint (e.g., token revocation, session logout) is not
  covered by this control and would require its own CSRF token or same-site cookie policy.
- **Trust assumption**: the `googleRedirectUri` environment variable (`GMAIL_REDIRECT_URI` /
  `CALENDAR_REDIRECT_URI`) must be registered as an authorized redirect URI in the Google Cloud
  Console. A misconfigured or overly broad registered URI would undermine the redirect-binding
  that the state token enforces.
