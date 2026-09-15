# HTML Output Encoding — auth-gateway (the auth BFF)

> Every user-supplied value interpolated into an HTML email body is entity-encoded through `escapeHtml` before transmission, eliminating HTML injection and stored XSS via notification emails.

## What it is (the concept)

**Output encoding** (also called **HTML escaping** or **HTML entity encoding**) is the practice of converting characters with special meaning in HTML — `&`, `<`, `>`, `"`, `'` — into their safe entity equivalents (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`) before inserting untrusted data into an HTML context. This is the primary **sink-side defence** against **Cross-Site Scripting (XSS)**: it breaks the browser's ability to interpret attacker-controlled strings as markup or script regardless of what those strings contain. Applied at a single central rendering function, it cannot be accidentally omitted by individual callers.

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/xss.md).

In this app the realistic threat vector is **stored/content XSS via notification emails**: an attacker registers with a crafted `email` address or username containing `<script>` or `<img onerror=…>` payloads. Without encoding, these payloads would be written verbatim into the HTML bodies of verification, password-reset, login-alert, and newsletter emails — executing in the recipient's mail client (which often renders HTML) or in any web-based email viewer.

## How auth-gateway implements it

All HTML email rendering is funnelled through a single function in
[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs).

**`escapeHtml` — the encoding primitive (lines 350–352):**

```js
function escapeHtml(value) {
    return String(value)
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;').replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
}
```

All five OWASP-mandated characters are covered.

**`renderEmailTemplate` — the central, mandatory encoding gate (lines 375–381):**

```js
function renderEmailTemplate(fileName, variables) {
    const html = readFileSync(resolve(emailTemplateDir, fileName), 'utf8');
    return html.replaceAll(/{{\s*([\w.-]+)\s*}}/g, (_match, rawKey) => {
        const key = String(rawKey).replace(/^\./, '');
        return escapeHtml(variables[key] ?? variables[rawKey] ?? 'unknown');
    });
}
```

The regex matches every `{{placeholder}}` in the template file and passes the resolved variable unconditionally through `escapeHtml`. There is no code path that substitutes a variable directly; even a missing key falls back to the literal string `'unknown'`, which is itself safe.

**All send-email helpers use this gate exclusively:**

| Helper | Template |
|---|---|
| `sendLoginSecurityNotification` | `login-alert.html` |
| `sendAccountCreatedNotification` | `account-created.html` |
| `sendEmailVerification` | `email-verification.html` |
| `sendPasswordReset` | `password-reset.html` |
| `sendNewsletterConfirm` | `newsletter-confirm.html` |
| `sendNewsletterWelcome` | `newsletter-welcome.html` |
| `sendNewsletterUnsubscribe` | `newsletter-unsubscribe.html` |

Every helper passes the user-supplied `email` (and, where applicable, `token`, `resetUrl`, `confirmUrl`) as values to `renderEmailTemplate`. None of them construct raw HTML strings manually.

## How we know it is applied

The wiring is structural, not aspirational: `renderEmailTemplate` is the **only** function that reads an HTML template file (`readFileSync`) and the **only** place where `{{…}}` substitution occurs. The `escapeHtml` call is inside that function's regex replacement callback, making it impossible to invoke template rendering without encoding.

A static search confirms no direct template-string interpolation of user data elsewhere in the file:

```
grep -n 'html:' apps/opposite-osiris/scripts/auth-gateway.mjs
# → every hit resolves to renderEmailTemplate(...)
```

Lines 468, 479, 488, 497, 506, 515, 524 all assign `html: renderEmailTemplate(...)` — no call site constructs raw HTML.

## Reference

The [Cross Site Scripting Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html) (OWASP) identifies **HTML entity encoding at the output point** as Rule 1 — the foundational control for HTML contexts. The implementation here applies that rule at a single, mandatory choke-point (`renderEmailTemplate`) rather than at each individual call site, which is the pattern the cheat sheet recommends to avoid omission errors.

## Residual risk / assumptions

- **Email client rendering variance.** The encoding protects HTML contexts; email clients that mishandle `Content-Type: text/html` or strip entity encoding in unusual ways are outside the gateway's control.
- **Template files themselves.** `escapeHtml` encodes dynamic variables, not static template markup. If an attacker can modify the HTML template files on disk (e.g., through a separate file-write vulnerability), those static parts are not encoded. Template files must be treated as privileged assets.
- **`Token` and URL fields.** Values like `Token` and `ResetURL` are passed to `renderEmailTemplate` and are therefore entity-encoded in the HTML. However, these values are placed inside `href` attributes in the templates; correct URL encoding of any attacker-influenced URL component is a separate concern (URL injection / open redirect) not fully addressed by HTML entity encoding alone.
- **Non-email output.** This control applies only to HTML email bodies. JSON API responses, HTTP headers, and redirect targets are governed by separate controls (see [`input-validation.md`](./input-validation.md), [`cors-misconfiguration.md`](./cors-misconfiguration.md)).
