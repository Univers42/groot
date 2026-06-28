# Cross-Site Scripting (XSS)

> A class of injection attack where untrusted data is inserted into a web page and executed as script in the victim's browser, bypassing the same-origin policy.

## What it is

Cross-Site Scripting occurs when a web application incorporates user-supplied or third-party data into its output without properly escaping or validating it, allowing an attacker to deliver executable code to other users. The browser has no way to distinguish between the application's own script and the injected payload — both arrive over the same origin, so the injected code runs with full access to the page's DOM, cookies, and local storage. XSS is categorised into three families: **reflected** (payload travels in the request and is echoed back immediately), **stored** (payload is persisted in a database or file and re-served to all subsequent visitors), and **DOM-based** (the injection and execution happen entirely on the client side, never touching the server's HTTP response body). All three families share the same root cause: a trust boundary violation where attacker-controlled strings are treated as executable code rather than inert data.

## How the attack works

1. **Identify an injection point.** The attacker locates a location where user input is reflected or stored and later rendered — a search box, a comment field, a URL parameter, a user profile field, or a WebSocket message.
2. **Craft a payload.** A script fragment is constructed that will execute when the browser parses the page. The attacker keeps it minimal: establish a callback channel, then exfiltrate a target value.
3. **Deliver the payload.** For reflected XSS the attacker sends the victim a crafted URL (via phishing, shortened link, or open redirect). For stored XSS, the payload is submitted once and then fires for every user who loads the affected page.
4. **Browser executes the injected code.** The victim's browser parses the HTML, encounters the script, and runs it in the context of the legitimate origin. Session cookies marked without `HttpOnly` are readable; any in-page action can be scripted; the page's visual content can be rewritten.
5. **Attacker collects the result.** Exfiltrated tokens, keystrokes, or re-rendered login forms arrive at an attacker-controlled endpoint.

**Illustrative, non-weaponized example.** Suppose an application renders a search term directly into HTML without encoding:

```html
<!-- Application output (vulnerable) -->
<p>Results for: <strong>laptop</strong></p>
```

If the search term is not sanitised, a query string containing an `<img>` tag with an `onerror` handler would cause the browser to execute arbitrary script in the page's origin context. The following snippet shows the *structure* of such a payload — it is intentionally incomplete and targets no real system:

```html
<!-- Illustrative structure only — not a working exploit -->
<img src="x" onerror="/* attacker script here */">
```

A Content Security Policy that restricts `script-src` to explicit allowlisted sources would block this execution even when the injection point exists, because the browser enforces the policy before running any inline or injected script.

## Real-world impact

XSS is not a theoretical risk. The OWASP Top Ten 2017 documented that XSS was "found in around two thirds of all applications," making it the second most prevalent class of vulnerability across all audited codebases at that time. The practical consequences range from session hijacking (an attacker silently copies a victim's authenticated session token and replays it from a separate machine, taking over the account without ever knowing the password) to credential harvesting via injected fake login forms, to full page defacement. In regulated industries — healthcare, banking, government — even a single stored XSS payload on an authenticated page can result in mass account compromise across every user who views that page, triggering mandatory breach notifications under GDPR and similar frameworks. OWASP documents the impact category as covering confidentiality loss (session token theft), integrity loss (DOM manipulation), and in some configurations availability loss; see the classification link below for the authoritative breakdown.

Source: [OWASP Top Ten 2017 — A7: Cross-Site Scripting](https://owasp.org/www-project-top-ten/2017/A7_2017-Cross-Site_Scripting_(XSS))

## OWASP classification

XSS is catalogued as **A03:2021 — Injection** in the current OWASP Top Ten and has its own dedicated community page. The canonical defensive guidance lives in the Content Security Policy Cheat Sheet, which covers policy syntax, nonce-based allowlisting, `strict-dynamic`, reporting endpoints, and migration strategy for legacy applications.

- [Cross-Site Scripting (XSS) — OWASP Foundation](https://owasp.org/www-community/attacks/xss/)
- [Content Security Policy Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html)

## How defenders stop it

- **Output encoding:** Every untrusted value rendered into HTML, JavaScript, CSS, or URL contexts must be escaped for that specific context. Generic HTML entity encoding is insufficient for JavaScript string contexts — use context-aware encoding libraries.
- **Content Security Policy (CSP):** Deploy a `Content-Security-Policy` response header that restricts `script-src` to specific nonces or hashes. A nonce-based policy (`script-src 'nonce-<random>'`) ensures that only server-generated script tags with the matching nonce execute; injected payloads lack the nonce and are blocked. Avoid `'unsafe-inline'` and `'unsafe-eval'`.
- **`HttpOnly` and `Secure` cookie flags:** Mark session cookies `HttpOnly` so that even a successful script injection cannot read them via `document.cookie`. Use `Secure` to prevent transmission over plaintext channels.
- **`SameSite` cookie attribute:** Set `SameSite=Lax` or `SameSite=Strict` on session cookies to constrain cross-origin request forgery that often accompanies XSS.
- **Input validation and allowlisting:** Reject or strip HTML where rich text is not required. For fields that must accept markup (rich text editors), use a well-maintained allowlist sanitiser (e.g., DOMPurify) rather than a blocklist.
- **Subresource Integrity (SRI):** For any third-party scripts loaded from CDNs, add `integrity` attributes so the browser refuses tampered payloads.
- **CSP reporting:** Configure `report-uri` or `report-to` to collect policy violations in production, enabling detection of injection attempts before they are refined into successful exploits.

In this project, see the defenses: [grobase](../defense/grobase/security-headers-csp.md), [opposite-osiris](../defense/opposite-osiris/security-headers-csp.md), [platform](../defense/platform/security-headers-csp.md).

## References

- [Content Security Policy Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html)
- [Cross-Site Scripting (XSS) — OWASP Foundation](https://owasp.org/www-community/attacks/xss/)
- [OWASP Top Ten 2017 — A7:2017 Cross-Site Scripting (XSS)](https://owasp.org/www-project-top-ten/2017/A7_2017-Cross-Site_Scripting_(XSS))
