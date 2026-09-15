# Cryptographic Failures — mail and calendar (Google OAuth apps)

> Google OAuth access and refresh tokens are persisted exclusively on the server side with mode `0o600` and are never included in any client-facing API response; the bridge exposes only a boolean connection status, the account email, and a last-sync timestamp.

## What it is (the concept)

**Sensitive credential material** — in this case OAuth **access tokens** and **refresh tokens** — must never be transmitted to or stored where untrusted parties can reach them. The risk is not a weak cipher but **absent confidentiality boundaries**: tokens that travel to the browser or sit world-readable on disk are effectively plaintext secrets. The correct control is **server-side-only storage** with the least permissive filesystem mode, combined with a **minimal-disclosure API** that strips token fields before serialisation.

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md).

In this app context the threat is twofold. An **XSS or network attacker** intercepting API responses could harvest a long-lived Google refresh token, granting permanent access to the user's Gmail or Calendar data without their knowledge. Simultaneously, a **local-privilege attacker** on the same host (shared container, misconfigured multi-user setup) could read a world-readable token file and impersonate the authenticated Google account. Both paths are closed here.

## How mail-calendar implements it

### Token file written at `0o600`

Both bridges use a single `writeTokens` function as the only token-persistence path. The file is created with restrictive permissions that deny read/write to the group and all others:

`apps/mail/bridge/server.mjs` — lines 209–211:
```js
function writeTokens(tokens) {
  mkdirSync(dirname(tokenFile), { recursive: true });
  writeFileSync(tokenFile, JSON.stringify(tokens, null, 2), { mode: 0o600 });
}
```

`apps/calendar/bridge/server.mjs` — lines 178–180: identical pattern with `{ mode: 0o600 }`.

The same `0o600` mode is applied to the OAuth **state file** (`writeStates`) in both bridges, preventing cross-request state injection.

### `publicSession` strips all token material

The single serialiser used by every status/session endpoint constructs the client response from the token object without forwarding token fields. Mail bridge (`apps/mail/bridge/server.mjs`, lines 252–269) and calendar bridge (`apps/calendar/bridge/server.mjs`, lines 587–603) both return only:

```js
{
  provider, configured, connected,   // boolean — never the token itself
  account,                           // account email string
  lastSync,                          // ISO timestamp or null
  message, callback, baas            // non-secret diagnostics
}
```

The `connected` boolean is derived with `Boolean(tokens?.refresh_token || tokens?.access_token)` — the token is consumed in-process to compute a boolean; the value is discarded before serialisation.

### Token files excluded from version control

`apps/mail/.gitignore` (lines 9–10) explicitly excludes the token and state files:

```
.mail-bridge-tokens.json
.mail-bridge-state.json
```

`apps/calendar/.gitignore` uses the glob `.calendar-bridge-*.json`, which covers both the token and state files for the calendar bridge. Neither file can be accidentally committed.

## How we know it is applied

The `publicSession` function is the **only serialisation path** invoked by the bridge HTTP handlers. In the mail bridge (line 252) and calendar bridge (line 587), there is no alternative route that returns raw tokens; `readTokens()` is called inside `publicSession` solely to derive the `connected` boolean and extract `account`/`lastSync`. The `writeTokens` call sites in both bridges pass no `mode` argument other than `0o600` — there is no fallback write path.

In the calendar bridge the `accessToken()` helper (line 233) returns the raw access token **only to internal Node.js callers** (Google API fetch calls within the same process) and is never exposed to an HTTP handler directly. The same design applies in the mail bridge.

The `.gitignore` exclusions have been in place since initial commit; `git ls-files apps/mail apps/calendar` returns no token or state JSON files.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/) catalogues the failure modes that arise when sensitive data is inadequately protected — not only through weak algorithms but through absent access controls on stored credentials. The control implemented here directly addresses the subcategory of **credentials in insecure storage and insecure transmission**, which OWASP identifies as among the most exploited in OAuth-integrated applications.

## Residual risk / assumptions

- **Single-user, single-container trust boundary.** The `0o600` mode prevents other OS users from reading the token file, but if the container runs as `root` (or any process inside the container is compromised), the mode provides no additional protection. The control assumes the container process runs as a non-root user or that the container itself is the isolation boundary.
- **In-memory exposure window.** Between `readTokens()` and internal use, the refresh token lives in the Node.js heap. A heap dump or a Node.js inspector attached to the process would expose it. There is no additional in-memory encryption.
- **Single-account architecture.** Both bridges store one token file per service. Multi-user or multi-account scenarios are not addressed; a second user connecting would overwrite the first user's tokens.
- **No token rotation enforcement.** The bridge refreshes access tokens when they expire but does not implement forced rotation or revocation on suspicious activity. Refresh token leakage before expiry cannot be detected locally.
- **Client secret stored in env.** `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are loaded from environment variables at process start. Their security depends entirely on the confidentiality of the Docker environment and the vault42 secret store — this document covers the token-handling layer only.
