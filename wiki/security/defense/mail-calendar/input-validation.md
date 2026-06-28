# Input Validation — mail and calendar (Google OAuth apps)

> The OAuth scopes requested from Google are hardcoded server-side constants; no caller-supplied value can influence which permissions are granted.

## What it is (the concept)

**Input validation** is the practice of rejecting or ignoring any externally supplied value that does not conform to a known-good specification before that value is used in a security-sensitive decision. In the OAuth context this takes the form of a **fixed allowlist**: the set of scopes submitted to the authorization server is determined solely by immutable module-level constants, not by query parameters, request headers, or any other client-controlled input. The key vocabulary here is **scope injection** — an attack class where a manipulated OAuth flow requests broader permissions than the application intends.

## What it defends against

See [Injection Attacks (SQLi, XSS, Command Injection)](../../attack/input-validation.md).

In the mail and calendar context the concrete threat is **privilege escalation via scope widening**: an attacker who can influence the authorization request URL could cause Google to grant tokens with permissions far beyond what the app requires — for example substituting `gmail.readonly` with `https://mail.google.com/` (full IMAP access) or appending `https://www.googleapis.com/auth/admin.directory.user` (GSuite directory). Because mail uses `gmail.modify` instead of the unrestricted `https://mail.google.com/` scope, even a compromised token cannot permanently delete messages or alter account settings.

## How mail-calendar implements it

Both bridges define their scope sets as **module-level frozen arrays** that are evaluated once at process startup and never re-assigned.

**Mail** — [`apps/mail/bridge/server.mjs`](../../../../apps/mail/bridge/server.mjs), lines 56-58:

```js
const gmailScopes = [
  'https://www.googleapis.com/auth/gmail.modify',
];
```

At authorization time (line 768) the `URLSearchParams` object passed to Google is built exclusively from this constant:

```js
scope: gmailScopes.join(' '),
```

No code path reads a scope value from `req.query`, `req.body`, or any other request-derived source.

**Calendar** — [`apps/calendar/bridge/server.mjs`](../../../../apps/calendar/bridge/server.mjs), lines 53-58:

```js
const googleScopes = [
  'openid',
  'email',
  'profile',
  'https://www.googleapis.com/auth/calendar',
];
```

Likewise consumed at authorization time (line 617) as `scope: googleScopes.join(' ')` with no runtime substitution.

In both bridges the `startAuth` function constructs the full `URLSearchParams` object (including `client_id`, `redirect_uri`, `response_type`, `state`, `access_type`, and `prompt`) and passes it directly to the Google authorization endpoint via a `302` redirect — the scope value is never interpolated from user input at any point in that construction.

## How we know it is applied

The `startAuth` handler in each bridge is the **only** code path that constructs the Google authorization URL. Both handlers are self-contained functions with no parameters; they receive only an HTTP `response` object and build the redirect entirely from module-scope constants. A grep over both files confirms there is no assignment to `gmailScopes` or `googleScopes` after their initial declaration, and no `req`/`request`-derived variable is referenced inside the `URLSearchParams` constructor:

```
apps/mail/bridge/server.mjs:768:    scope: gmailScopes.join(' '),
apps/calendar/bridge/server.mjs:617:    scope: googleScopes.join(' '),
```

These are the only occurrences of `scope:` as an object key in both files, confirming there is no alternative authorization path that could pass a different scope.

## Reference

The OWASP Input Validation Cheat Sheet ([https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)) establishes that validation must occur server-side against an allowlist of acceptable values, and that client-supplied data must never be trusted to govern security-sensitive parameters. The scope-as-constant pattern in these bridges is a direct application of that principle: the "allowlist" is the source array itself, and the validation is structural — there is no code path through which an out-of-list value can reach Google's authorization endpoint.

## Residual risk / assumptions

- **Google's token response is trusted without scope verification.** Neither bridge checks the `scope` field in the token response to assert that Google returned exactly the requested scopes and no others. If Google were to grant a superset (theoretically possible with certain account configurations), the bridge would silently accept it.
- **The `GMAIL_CALLBACK_PATHS` and `CALENDAR_CALLBACK_PATHS` environment variables** extend the set of accepted redirect URIs (lines 53-54 in mail, 48-50 in calendar). If an operator misconfigures these to include an attacker-controlled origin, the CSRF `state` parameter is still verified on callback, but redirect validation would be weakened.
- **Scope constants are set at process startup from source code**, so a supply-chain compromise of the bridge source (e.g., a malicious dependency rewriting the constant before first use) would bypass this control entirely.
- This control addresses scope injection only. It does not validate the content of Gmail message bodies or Calendar event fields fetched from Google — those data paths are treated as trusted third-party responses and passed through without sanitization.
