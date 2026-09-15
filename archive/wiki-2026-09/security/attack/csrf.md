# Cross-Site Request Forgery (CSRF)

> A CSRF attack tricks an authenticated user's browser into sending an unintended, forged request to a web application — carrying that user's credentials without their knowledge or consent.

## What it is

Cross-Site Request Forgery exploits the trust a web application places in an authenticated browser session. When a user is logged in to a site, the browser automatically attaches session cookies to every outbound request to that origin. An attacker who can cause that browser to issue a crafted request — by embedding it in a page, email, or image tag on a site they control — can piggyback on those credentials to perform actions as the victim. The vulnerability is not in the browser itself; it is in the application's failure to distinguish between intentional user actions and silently injected ones. CSRF is distinct from XSS: XSS runs injected code inside the trusted origin, while CSRF forges requests *from* an external origin *toward* the trusted one. The attack succeeds even when the victim is otherwise security-conscious, because nothing in the browser's default behaviour blocks cross-origin form submissions or image fetches.

## How the attack works

1. **Victim authenticates.** The user logs in to `bank.example.com`; the server issues a session cookie stored in the browser.
2. **Attacker crafts the payload.** The attacker builds a page (or an HTML email) containing a form or resource that, when rendered, fires a state-changing request to the target application — for example, a funds-transfer endpoint.
3. **Victim visits the attacker's page.** While still logged in, the victim clicks a link or visits a URL controlled by the attacker.
4. **Browser auto-attaches credentials.** The browser renders the attacker's page and silently sends the crafted request to `bank.example.com`, including the valid session cookie.
5. **Server honours the request.** Because the cookie looks legitimate, the server processes the transfer — or whatever privileged action the attacker targeted — without the user's knowledge.

**Illustrative (non-weaponized) example:**

```html
<!-- attacker-controlled page — illustrative only -->
<form id="f" action="https://app.example/api/change-email" method="POST">
  <input type="hidden" name="email" value="attacker@evil.example">
</form>
<script>document.getElementById('f').submit();</script>
```

If `app.example` validates only the session cookie and not a separate anti-CSRF token, this form submits silently when an authenticated user lands on the attacker's page, changing their registered email address.

## Real-world impact

In 2008, a CSRF vulnerability in the uTorrent BitTorrent client's built-in web interface was exploited on a broad scale. Because the interface accepted GET-based commands and did not require any token beyond an active session, attackers embedded crafted URLs in web pages that, when visited by a user running uTorrent, caused the client to silently add and start malicious torrents — resulting in mass malware delivery to affected machines. The incident illustrated that CSRF is not limited to bank transfers or account takeover; any application that accepts session-authenticated state-changing requests without verifying intent is exposed. See the OWASP CSRF community page for attribution: [https://owasp.org/www-community/attacks/csrf](https://owasp.org/www-community/attacks/csrf).

## OWASP classification

CSRF appears in the OWASP historical Top Ten and remains a foundational web application weakness. OWASP maintains a dedicated prevention cheat sheet covering token-based defences, `SameSite` cookie semantics, and framework-specific guidance:

**CSRF Prevention Cheat Sheet** — OWASP Cheat Sheet Series
[https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)

The OWASP community attack reference is at:
[https://owasp.org/www-community/attacks/csrf](https://owasp.org/www-community/attacks/csrf)

## How defenders stop it

- **Synchroniser token pattern.** Generate a cryptographically random, per-session (or per-form) token; embed it as a hidden field or request header; reject any request where the server-held token does not match the submitted one. An attacker's cross-origin page cannot read this token due to the Same-Origin Policy.
- **`SameSite` cookie attribute.** Set session cookies to `SameSite=Lax` (safe default) or `SameSite=Strict` (highest restriction). This instructs browsers to withhold the cookie from cross-site navigations, breaking the attack vector without requiring explicit token management in most modern browsers.
- **Double-submit cookie.** Where server-side token storage is impractical, issue a signed random value as both a cookie and a request parameter; verify they match. Use HMAC-signed values to prevent the "cookie tossing" bypass.
- **`Origin` / `Referer` header verification.** Check that the `Origin` or `Referer` header of state-changing requests matches the expected application origin. Treat absent headers cautiously: reject unless a deliberate policy allows them.
- **Custom request headers (AJAX).** Require a custom header (e.g., `X-Requested-With: XMLHttpRequest`) for API calls. Cross-origin requests cannot add arbitrary headers without a preflight CORS response — which the server should not grant for sensitive endpoints.
- **User interaction confirmation.** For high-impact actions (fund transfers, email/password changes, account deletion), require re-authentication or an explicit CAPTCHA step — even a valid CSRF token cannot confirm conscious user intent.
- **Avoid state-changing GET requests.** Reserve `GET`, `HEAD`, and `OPTIONS` for safe, idempotent operations only. GET-based state changes are trivially exploitable via `<img src="...">` without any form interaction.

In this project, see the defenses: [opposite-osiris](../defense/opposite-osiris/csrf.md), [auth-gateway](../defense/auth-gateway/csrf.md), [mail-calendar](../defense/mail-calendar/csrf.md).

## References

- OWASP CSRF Prevention Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP Community: Cross-Site Request Forgery — <https://owasp.org/www-community/attacks/csrf>
