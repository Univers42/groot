# CORS Origin Restriction — mail and calendar (Google OAuth apps)

> The mail bridge pins `Access-Control-Allow-Origin` to a single configured origin, preventing any other web page from reading the authenticated user's Gmail data through the local bridge process.

## What it is (the concept)

**Cross-Origin Resource Sharing (CORS)** is the browser mechanism that enforces which origins may read responses from a different origin. A server signals its policy through the `Access-Control-Allow-Origin` (ACAO) response header. Setting ACAO to `*` (wildcard) means any web page the user has open can issue credentialed or uncredentialed cross-origin reads against that server. **Origin restriction** means pinning ACAO to exactly one trusted origin, so the browser blocks all cross-origin reads from any other page. The mail bridge is a localhost HTTP process that holds Google OAuth tokens on disk and authorizes requests purely by the token it has stored — making a narrow, explicit origin allowlist the primary browser-layer gate.

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md). In the mail-calendar context, both bridge processes run as localhost HTTP servers that carry long-lived Google OAuth tokens. Without an origin restriction, any malicious web page the authenticated user visits could silently fetch `/messages`, `/threads`, or `/events` from `http://localhost:<port>` and exfiltrate the full mailbox or calendar. The threat is elevated here because the bridges carry no per-request auth header — the token is already on disk and applied server-side.

## How mail-calendar implements it

**Mail bridge** (`apps/mail/bridge/server.mjs`):

- Line 37 reads the allowed origin from the environment:
  ```js
  const appOrigin = process.env.MAIL_APP_ORIGIN || 'http://localhost:3002';
  ```
- Lines 166–174, the `json()` serializer emits a scoped ACAO header on every JSON response:
  ```js
  'Access-Control-Allow-Origin': appOrigin,
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  ```
- Lines 176–180, the `html()` serializer applies the same `appOrigin` value to HTML responses (the OAuth callback page).
- Line 902, the top-level router handles all `OPTIONS` preflight requests through the same `json()` path, so preflight responses also carry the restricted origin, not a wildcard:
  ```js
  if (request.method === 'OPTIONS') return json(response, 204, {});
  ```

Because `json()` and `html()` are the only two response serializers in the file, every response the bridge emits — data, errors, and preflight — carries `Access-Control-Allow-Origin: <configured-origin>`.

**Calendar bridge** (`apps/calendar/bridge/server.mjs`): the calendar bridge does **not** implement this control. Its `json()` (line 89) and `html()` (line 99) serializers both emit `Access-Control-Allow-Origin: *`. See Residual risk below.

## How we know it is applied

The `json()` and `html()` helpers are the sole response code paths in `apps/mail/bridge/server.mjs`. There is no alternative `writeHead` call that could bypass them. Any route that responds — including error branches — calls one of these two functions, so the scoped ACAO header is unconditionally emitted in the mail bridge. The `MAIL_APP_ORIGIN` environment variable is wired through the project's `.env.local` / Docker environment injection, giving operators control over the exact allowed origin per deployment.

## Reference

The [HTML5 Security Cheat Sheet — Cross-Origin Resource Sharing](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html) published by OWASP details the risks of overly permissive CORS policies and recommends explicit origin allowlisting as the primary mitigation. The mail bridge implementation matches that recommendation by resolving the permitted origin at startup from a named environment variable rather than hardcoding it, so the allowlist can be narrowed or rotated without a code change.

## Residual risk / assumptions

- **Calendar bridge is fully open.** `apps/calendar/bridge/server.mjs` uses `Access-Control-Allow-Origin: *` for both `json()` and `html()` responses. Any web page the user visits can read calendar data from the local bridge. This is an active misconfiguration in the current codebase.
- **localhost-only assumption.** Both bridges are designed to run on localhost. The CORS restriction in the mail bridge provides no protection if the bridge is accidentally exposed on a routable interface, since cross-origin reads from the local network would still be blocked by the browser CORS policy, but server-side listeners would accept direct connections that bypass the browser entirely.
- **No `Vary: Origin` header.** The mail bridge does not emit `Vary: Origin`, which means intermediate caches (unlikely but possible) could serve a response cached for one origin to a different origin.
- **Single static origin.** `MAIL_APP_ORIGIN` accepts exactly one string; there is no multi-origin allowlist. If the mail app is served from more than one origin (e.g., HTTP and HTTPS variants during development), one of them will be blocked.
- **No credentials flag enforcement.** The bridge does not set `Access-Control-Allow-Credentials: true`, which is correct — but it also means it cannot validate that requests include a credential. Authorization relies entirely on the token stored on disk; any page that can reach the bridge (same origin, or calendar's wildcard) can read data without presenting a credential.
