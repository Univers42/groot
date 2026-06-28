# Clickjacking Defense — mail and calendar (Google OAuth apps)

> Both apps open the OAuth provider window with `noopener,noreferrer`, ensuring the newly opened tab can never read or navigate the opener application window.

## What it is (the concept)

**Clickjacking** (also called a **UI redress attack**) is a technique in which an attacker overlays a transparent or opaque iframe on top of a legitimate page, tricking users into clicking controls they cannot see. The related vector defended here is **reverse tabnabbing**: when a page opens a new tab via `window.open`, the new tab can hold a reference to the opener via `window.opener` and silently redirect it to a phishing page while the user is away authenticating. Passing `noopener` in the window-features string nullifies `window.opener` in the child tab; `noreferrer` additionally suppresses the `Referer` header and implies `noopener` in older engines.

## What it defends against

See [Clickjacking (UI Redress Attack)](../../attack/clickjacking.md).

The concrete threat in this context is reverse tabnabbing during the Google OAuth popup flow. A user clicks "Connect Google" and is taken to an external authorization page; without `noopener`, that external page (or any redirect chain it traverses, including a compromised OAuth endpoint) could call `window.opener.location = 'https://phishing.example'` and replace the still-running mail or calendar app with a credential-harvesting clone — silently, without any browser warning.

## How mail-calendar implements it

Both apps share the same defensive pattern, applied at the single function that initiates the OAuth popup in each bridge library:

**Mail** — [`apps/mail/src/lib/mailBridge.ts`](../../../../apps/mail/src/lib/mailBridge.ts), `openBridgeAuth` (line 66):

```ts
const authWindow = globalThis.open(
  `${bridgeBase(endpoint)}/auth/${provider}/start`,
  '_blank',
  'noopener,noreferrer'
);
if (!authWindow) throw new Error('The browser blocked the provider authorization window.');
```

**Calendar** — [`apps/calendar/src/lib/calendarBridge.ts`](../../../../apps/calendar/src/lib/calendarBridge.ts), `openCalendarAuth` (line 72):

```ts
const authWindow = globalThis.open(
  `${bridgeBase(endpoint)}/auth/google/start`,
  '_blank',
  'noopener,noreferrer'
);
if (!authWindow) throw new Error('The browser blocked the Google Calendar authorization window.');
```

`globalThis.open` is used rather than `window.open` so the call is SSR-safe in environments where `window` may be undefined. The window-features string `'noopener,noreferrer'` is passed as the third argument, which instructs the browser to open the tab without a back-reference to the opener and without leaking the `Referer` header to the OAuth endpoint.

These two functions are the **only** code paths in each app that launch the OAuth flow from the UI; there is no alternative call-site that could inadvertently omit the features string.

## How we know it is applied

The control is structural: `openBridgeAuth` and `openCalendarAuth` are the exclusive entry points to the OAuth popup in their respective apps, and both hard-code the `noopener,noreferrer` features string unconditionally. Any future caller of these functions inherits the protection without needing to pass extra arguments. The `if (!authWindow)` guard additionally surfaces popup-blocker failures as explicit errors rather than silent no-ops, making integration testing observable.

## Reference

The [OWASP Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html) covers both framing prevention (via `X-Frame-Options` / `frame-ancestors`) and reverse tabnabbing mitigations. The `noopener` pattern implemented here directly addresses the tabnabbing variant described in that guide — a complementary concern to classical iframe-based clickjacking rather than a substitute for `Content-Security-Policy: frame-ancestors`.

## Residual risk / assumptions

- **This control does not set `X-Frame-Options` or a `frame-ancestors` CSP directive.** If an attacker embeds the mail or calendar app itself inside an iframe on a third-party page, the classical clickjacking vector (transparent overlay to steal clicks) is not mitigated here; that requires a server-side response header, not a client-side `window.open` flag.
- **The OAuth callback route is excluded.** Once the provider redirects back to the bridge server (the `osionos-bridge` or equivalent), the security of that redirect handling — CSRF state parameter verification, session binding — is a separate concern and is not addressed by this control.
- **Popup blocker behaviour is unhandled beyond error-throwing.** If the browser blocks the popup and the caller catches the thrown error silently, the user receives no feedback and the auth flow stalls — a UX issue, not a security regression, but worth noting.
- **`noreferrer` hides referrer context from the OAuth provider.** Some providers log or validate the referrer for anomaly detection; suppressing it is the safer choice here but removes that server-side signal.
