# OAuth State Integrity — mail and calendar (Google OAuth apps)

> Every OAuth authorization callback is validated against a single-use, time-bounded state token: once consumed or expired, the same callback URL cannot authorize a second exchange.

## What it is (the concept)

In the OAuth 2.0 authorization code flow, the **state parameter** is an opaque, server-generated nonce sent to the authorization server and echoed back in the callback. Its role is twofold: binding the callback to the originating session (**CSRF protection**) and providing a short-lived, **single-use token** that becomes worthless after one successful exchange. The critical properties are **expiry** (a leaked state is harmless after its TTL) and **consumption** (the token is deleted at the moment it is read, so replaying the callback URL yields nothing).

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md).

An attacker who intercepts or extracts a live OAuth callback URL — through network capture, a browser history leak, a logged redirect, or a phishing page — can attempt to replay it and hijack the resulting Google token. Without an expiry, a leaked state is valid indefinitely. Without single-use deletion, the same callback can be replayed repeatedly. Both conditions are closed in these bridges.

## How mail-calendar implements it

Both bridges share the same three-function pattern; the implementations are independent but structurally identical.

**TTL constant** — configurable via environment variable, defaulting to 10 minutes:

- [`apps/mail/bridge/server.mjs` line 50](../../../../apps/mail/bridge/server.mjs):
  ```js
  const oauthStateTtlMs = Number(process.env.MAIL_BRIDGE_OAUTH_STATE_TTL_MS || 10 * 60 * 1000);
  ```
- [`apps/calendar/bridge/server.mjs` line 46](../../../../apps/calendar/bridge/server.mjs):
  ```js
  const oauthStateTtlMs = Number(process.env.CALENDAR_BRIDGE_OAUTH_STATE_TTL_MS || 10 * 60 * 1000);
  ```

**`pruneStates()`** — called on every read; silently discards any entry whose `createdAt` is older than the TTL before the map is inspected or written:

- mail lines 224–226 / calendar lines 193–195:
  ```js
  function pruneStates(states) {
    const now = Date.now();
    return Object.fromEntries(Object.entries(states).filter(([, value]) => now - value.createdAt < oauthStateTtlMs));
  }
  ```

**`consumeOauthState()`** — reads the pruned map, extracts the matching entry, deletes it, and persists the updated map before returning the value. A second call with the same key returns `null`:

- mail lines 235–241 / calendar lines 204–210:
  ```js
  function consumeOauthState(state) {
    const states = pruneStates(readStates());
    const value = states[state];
    delete states[state];
    writeStates(states);
    return value || null;
  }
  ```

The state file is written with `mode: 0o600` (owner-read-only), reducing the exposure window for a file-system side-channel.

## How we know it is applied

`consumeOauthState` is called unconditionally at the entry point of each callback handler, before any token exchange occurs:

- [`apps/mail/bridge/server.mjs` line 782](../../../../apps/mail/bridge/server.mjs) — inside `finishGmailAuth`:
  ```js
  const oauthState = state ? consumeOauthState(state) : null;
  ```
- [`apps/calendar/bridge/server.mjs` line 631](../../../../apps/calendar/bridge/server.mjs) — inside `finishGoogleAuth`:
  ```js
  const oauthState = state ? consumeOauthState(state) : null;
  ```

Any callback that arrives without a valid, unexpired, previously unseen state receives `null` from `consumeOauthState` and cannot proceed to the token exchange step.

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) specifies that tokens used in redirect-based flows must be short-lived and invalidated after first use, directly addressing both the TTL and the consumption requirements implemented here. These two properties together are what transform the state parameter from a simple nonce into a meaningful single-use credential.

## Residual risk / assumptions

- **State file location is trusted.** Both bridges write the state file to a local path (inside the container). A process with write access to that path can forge or delete states. Container isolation is the boundary.
- **No explicit state-mismatch error path instrumentation.** If `oauthState` is `null` (expired, replayed, or tampered), the callback handler silently rejects; there is no rate-limited alerting on repeated null returns from the same IP.
- **TTL is adjustable via env var.** An operator setting `MAIL_BRIDGE_OAUTH_STATE_TTL_MS` or `CALENDAR_BRIDGE_OAUTH_STATE_TTL_MS` to a very large value would reintroduce an extended-validity window. The default is safe; the operator is trusted.
- **Pruning is lazy (on read), not scheduled.** Expired entries accumulate until the next state operation. This is harmless for security (pruning occurs before any lookup) but means the state file can grow if few operations are performed.
- **Token exchange happens over HTTPS** (Google's endpoint), but the bridge itself must also be reached over TLS for the callback to be safe in transit — this is enforced by the reverse-proxy TLS termination in the root compose stack, not by the bridge code itself.
