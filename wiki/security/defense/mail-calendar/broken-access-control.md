# Broken Access Control — mail and calendar (Google OAuth apps)

> The redirect URI presented to Google is a server-side constant, and the OAuth callback handler fires only for an explicit allowlist of paths — user-supplied input never influences either value.

## What it is (the concept)

**Broken Access Control** occurs when an application permits users or external parties to influence decisions — such as where an authorization code is delivered — that must remain under server authority. In the OAuth 2.0 Authorization Code flow, the **redirect URI** is the single parameter that determines which endpoint receives the authorization code; if it can be manipulated, an attacker can divert the code to a URI they control. A complementary risk is **open callback enumeration**: treating any inbound path as a valid OAuth callback, which widens the attack surface beyond the intended endpoint.

## What it defends against

See [Unauthorized Access / Privilege Escalation](../../attack/broken-access-control.md).

In the mail and calendar context, the specific threat is **redirect_uri tampering**: an attacker crafts an authorization link whose `redirect_uri` points to an attacker-controlled server, causing Google to deliver the authorization code there. A secondary threat is **stray-endpoint abuse**: if arbitrary server paths handled the OAuth callback, a confused-deputy or path-confusion attack could trigger token exchange on an unintended route.

## How mail-calendar implements it

Both bridge servers apply the same two-layer defense.

**Layer 1 — server-fixed redirect URI.**
The redirect URI is derived entirely from server-side configuration:

- [`apps/mail/bridge/server.mjs` line 45](../../../../apps/mail/bridge/server.mjs):
  ```js
  const googleRedirectUri = process.env.GMAIL_REDIRECT_URI || `${bridgeOrigin}/auth/gmail/callback`;
  ```
- [`apps/calendar/bridge/server.mjs` line 45](../../../../apps/calendar/bridge/server.mjs):
  ```js
  const googleRedirectUri = process.env.CALENDAR_REDIRECT_URI || `${bridgeOrigin}/auth/google/callback`;
  ```

Neither value is taken from the incoming request. At auth-start, the server stores this URI alongside the CSRF state token (`saveOauthState(state, googleRedirectUri)` — mail line 763, calendar line 612). At token exchange, the stored value is used exclusively:

- mail line 810: `redirect_uri: oauthState.redirectUri`
- calendar line 653: `redirect_uri: oauthState.redirectUri`

This means the `redirect_uri` presented to Google at code-exchange is always the one the server decided at auth-start, not anything the callback request carries.

**Layer 2 — explicit callback path allowlist.**
Each bridge constructs a `callbackPaths` `Set` whose members are the pathname of `googleRedirectUri` plus any additional paths declared in an env variable:

- mail lines 51–54:
  ```js
  const callbackPaths = new Set([
    new URL(googleRedirectUri).pathname,
    ...String(process.env.GMAIL_CALLBACK_PATHS || '').split(',').map((p) => p.trim()).filter(Boolean),
  ]);
  ```
- calendar lines 48–51: identical structure, keyed on `CALENDAR_CALLBACK_PATHS`.

The route dispatcher gates `finishGmailAuth` / `finishGoogleAuth` entirely on this set:

- mail line 852: `if (callbackPaths.has(requestUrl.pathname)) { await finishGmailAuth(...) }`
- calendar line 698: `if (callbackPaths.has(requestUrl.pathname)) { await finishGoogleAuth(...) }`

Any path not in the set bypasses the callback handler entirely, regardless of what query parameters it carries.

## How we know it is applied

The control is not aspirational — it is the **only code path** through which the token exchange can be reached. The route dispatcher in both bridges is a cascade of `if` / `else if` guards; `finishGmailAuth` and `finishGoogleAuth` appear in exactly one branch each, and both branches are conditioned on `callbackPaths.has(requestUrl.pathname)`. There is no fallthrough or wildcard match. The redirect URI read at exchange (`oauthState.redirectUri`) is the value written by `saveOauthState` at auth-start — the callback request has no mechanism to overwrite it because the state object is stored server-side, keyed by the CSRF `state` parameter, and never re-serialized from request data.

## Reference

[A01 Broken Access Control — OWASP Top 10:2021](https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/) classifies redirect-URI manipulation as a representative instance of broken access control in OAuth flows. The controls described here directly address the OWASP guidance that applications must enforce access-control decisions server-side and never trust client-supplied values for sensitive parameters.

## Residual risk / assumptions

- **Env-var trust boundary.** `GMAIL_REDIRECT_URI` and `CALENDAR_REDIRECT_URI` are read from the process environment. If an attacker can write to `.env.local` or the container environment, they can change the registered URI — but this is a deployment-integrity problem, not a per-request attack surface.
- **Google Console registration.** The redirect URI must also be allowlisted in the Google OAuth application console. This implementation does not verify that alignment at runtime; a misconfigured console allowlist could admit a URI that the bridge's server constant was intended to restrict.
- **`GMAIL_CALLBACK_PATHS` / `CALENDAR_CALLBACK_PATHS` expansion.** Operators can widen the `callbackPaths` set via env variable. Any path added there becomes a live callback endpoint; care is required not to introduce paths that are also reachable through other application logic.
- **CSRF state validation is a co-dependency.** The redirect URI control prevents code delivery to a wrong endpoint, but preventing use of an intercepted code also depends on the CSRF `state` nonce check (`oauthState` lookup). If that check were bypassed, the redirect URI defense alone would not prevent authorization-code replay.
