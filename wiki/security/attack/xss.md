# Cross-Site Scripting (XSS)

> An injection attack in which an adversary plants malicious scripts inside content delivered by a trusted web application, causing victim browsers to execute that code in the application's security context.

## What it is

Cross-Site Scripting (XSS) is a client-side code injection vulnerability that arises when an application incorporates attacker-controlled data into a page without adequately encoding or sanitising it first. Because the browser receives the injected script as part of a response from a legitimate origin, it executes the payload under that origin's privileges — including access to cookies, session tokens, and the DOM. XSS is not a single technique but a family of related attack classes: **Reflected** (the payload travels in a request and bounces back in the immediate response), **Stored** (the payload is persisted server-side and served to every subsequent visitor), and **DOM-Based** (client-side JavaScript writes attacker data into the DOM without ever sending it to the server). Despite being one of the oldest web vulnerability classes, it remains consistently present in OWASP's top ten lists because output encoding is easy to get wrong and the attack surface grows every time a new rendering path is added to an application.

## How the attack works

1. **Identify an injection point.** The attacker locates a place where user-supplied input is reflected or stored and later rendered in a browser — a search box, a comment field, a URL parameter, an HTTP header echoed in a response, or a JavaScript variable populated from an API response.
2. **Craft a payload.** The attacker constructs input containing script syntax that the application fails to neutralise. The exact form depends on the rendering context (HTML body, HTML attribute, JavaScript string, URL, CSS).
3. **Deliver the payload.** For Reflected XSS the attacker distributes a crafted URL (via phishing, a short-link, or an open redirect). For Stored XSS the attacker simply submits the payload to any intake form that other users will later view.
4. **Victim's browser executes the script.** When the victim loads the page, the browser parses attacker-controlled markup as legitimate page content and runs the embedded script under the application's origin.
5. **Attacker achieves objective.** The script may exfiltrate the session cookie to an attacker-controlled endpoint, forge authenticated requests (CSRF-style), rewrite page content to phish credentials, or install a persistent browser backdoor via a BeEF-style hook.

**Illustrative example — Stored XSS in a comment field:**

A comment form that stores raw user input and later renders it directly in a template is vulnerable. Submitting the following as a comment body demonstrates the injection point (this is a non-functional illustration; the `alert` is a conventional harmless canary, not an exfiltration payload):

```html
Nice article! <script>alert('XSS canary — document.cookie would go here')</script>
```

Every user who loads the comment thread would trigger the injected script. A real attacker replaces `alert(...)` with code that `fetch`es the victim's cookie to an external collector, then redirects the browser so the victim notices nothing.

## Real-world impact

Stored XSS vulnerabilities have repeatedly enabled large-scale session-hijacking campaigns against social platforms and e-commerce sites. A well-documented category is the **self-propagating worm**: an XSS payload that, once executed in a victim's browser, clones itself into the victim's own posts or messages, spreading exponentially across a social graph. The documented 2005 Samy worm on MySpace — often cited as the first mainstream XSS worm — reached one million accounts in roughly 20 hours by exploiting a stored XSS flaw, demonstrating that the blast radius of a single injection point is not bounded by the number of users who click a malicious link but by every user who simply visits an infected page. Even without worm-style propagation, a stored XSS flaw in an admin panel is a full account-takeover path for every privileged user who opens a management view. See the OWASP community write-up for documented impact categories: [https://owasp.org/www-community/Cross_Site_Scripting\_(XSS)](https://owasp.org/www-community/Cross_Site_Scripting_\(XSS\)).

## OWASP classification

XSS maps to **A03:2021 – Injection** in the OWASP Top 10 (2021 edition) and has its own dedicated prevention guidance:

- **OWASP Cross Site Scripting Prevention Cheat Sheet** — the primary reference for output-encoding rules, trusted-type strategies, and framework-specific guidance:
  [https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)

- **OWASP XSS Attack Community Page** — taxonomy of attack variants and vectors:
  [https://owasp.org/www-community/Cross_Site_Scripting\_(XSS)](https://owasp.org/www-community/Cross_Site_Scripting_\(XSS\))

## How defenders stop it

- **Context-aware output encoding** — encode data for the specific rendering context in which it will appear (HTML entity encoding for HTML body; JavaScript string escaping for JS contexts; attribute encoding for HTML attributes; URL encoding for href/src values). One encoding strategy does not fit all contexts.
- **Content Security Policy (CSP)** — deploy a strict `Content-Security-Policy` header that disallows inline scripts (`script-src 'nonce-...'` or `'strict-dynamic'`) and restricts permitted script sources to known origins. CSP is a defence-in-depth layer, not a substitute for output encoding.
- **Trusted Types API** — enforce browser-level restrictions on DOM-sink writes (`innerHTML`, `document.write`, `eval`) by requiring all assignments to pass through typed, audited factories; eliminates an entire class of DOM-XSS sinks in supporting browsers.
- **Input validation and allowlisting** — reject or strip input that does not conform to expected format and length at ingestion time; this is a complement to output encoding, not a replacement.
- **HttpOnly and Secure cookie flags** — mark session cookies `HttpOnly` so they are not accessible to JavaScript even if a payload executes, reducing the value of cookie-theft payloads.
- **Framework escaping by default** — prefer templating engines and UI frameworks that escape output automatically (React JSX, Go `html/template`, etc.) and treat raw-output escape hatches (`dangerouslySetInnerHTML`, `v-html`, `template.HTML`) as security-sensitive call sites requiring explicit review.
- **Sanitise rich HTML input with an allowlist library** — when users must supply formatted content (markdown, WYSIWYG), parse it through a maintained sanitiser (e.g. DOMPurify) configured with a strict element/attribute allowlist rather than attempting ad-hoc regex filtering.
- **Security headers** — pair CSP with `X-Content-Type-Options: nosniff` and `X-Frame-Options` to reduce auxiliary attack surface.

In this project, see the defenses: [osionos](../defense/osionos/xss.md), [opposite-osiris](../defense/opposite-osiris/xss.md), [auth-gateway](../defense/auth-gateway/xss.md), [mail-calendar](../defense/mail-calendar/xss.md).

## References

- OWASP Cross Site Scripting Prevention Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html>
- OWASP XSS Attack Community Page — <https://owasp.org/www-community/Cross_Site_Scripting_(XSS)>
