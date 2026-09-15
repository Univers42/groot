# Reverse Tabnabbing

> A browser-side attack in which a malicious page opened via `target="_blank"` exploits the `window.opener` reference to silently redirect its parent tab to a phishing site while the user is looking elsewhere.

## What it is

Reverse tabnabbing is a client-side redirection attack that abuses the relationship browsers maintain between a tab and any tab it opens. When a page opens a link with `target="_blank"` (or via `window.open()`), the browser exposes the originating page's global object to the newly opened page through `window.opener`. An attacker who controls the destination page can use that reference to navigate the parent tab away — typically to a convincing phishing replica — without the user noticing, because the original domain was already trusted. The attack is classed under the broader OWASP A07:2021 category of Identification and Authentication Failures when it results in credential theft, and intersects with A03:2021 (Injection) when the link target itself is user-supplied. Although modern browsers have retrofitted implicit `noopener` semantics onto `target="_blank"`, older browsers and non-browser runtimes remain vulnerable, and explicit opt-in is still the correct default for any anchor that opens untrusted content.

## How the attack works

1. **Identify a vulnerable anchor.** The attacker finds (or injects) a link on a legitimate site that opens external content in a new tab — typically `<a href="..." target="_blank">` — without `rel="noopener"` or `rel="noreferrer"`.
2. **Host a malicious page at the linked destination.** The attacker controls the page the link points to, or compromises it. This page carries a short JavaScript payload that runs immediately on load.
3. **Redirect the opener.** The malicious page calls `window.opener.location.replace(...)` to navigate the original tab — the trusted domain — to an attacker-controlled phishing replica. The user is still looking at the newly opened tab; the redirect happens in the background.
4. **Harvest credentials.** When the user switches back to the original tab they see what appears to be a plausible session-expiry login prompt on the legitimate domain's look-alike. Credentials entered there go to the attacker.

**Illustrative (non-functional) snippet — what the attacker's page contains:**

```javascript
// Runs in the attacker's newly opened tab.
// window.opener is the parent tab's global if noopener was NOT set.
if (window.opener && window.opener.location) {
  // Replace the parent tab's URL with a phishing replica.
  // In a real attack the destination would impersonate the legitimate site.
  window.opener.location.replace("https://example-phishing-replica.invalid/login");
}
```

The redirect is silent; no permission is requested. The user sees the parent tab "navigate" naturally and attributes it to a session timeout or a normal reload.

## Real-world impact

The attack class came to widespread attention after Oren Hafif's 2015 disclosure of tabnabbing as a practical phishing vector and it was subsequently referenced in multiple OWASP advisories. The primary documented impact is credential phishing: a user tricked into re-entering a password on a spoofed login page loses those credentials with no browser warning. Secondary impacts include session hijacking when the target site uses URL-fragment-carried tokens, and reputation damage to the site hosting the vulnerable link (it becomes an unwitting phishing launchpad). Because the redirect is JavaScript-driven rather than network-layer, standard phishing filters that block known bad URLs are ineffective — the user's browser never makes a suspicious request until credentials are submitted. The OWASP community documents this attack class and its real-world exploitation history at the reference below.

## OWASP classification

Reverse tabnabbing is documented in the **OWASP Community Attack catalog** and is addressed by mitigations in the **OWASP HTML5 Security Cheat Sheet**. It intersects with:

- **A01:2021 – Broken Access Control** (the `window.opener` channel bypasses the same-origin isolation model users expect)
- **A07:2021 – Identification and Authentication Failures** (the downstream consequence is typically credential theft via phishing)

Canonical references:

- OWASP Attack description: <https://owasp.org/www-community/attacks/Reverse_Tabnabbing>
- OWASP HTML5 Security Cheat Sheet (Tabnabbing section): <https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html>

## How defenders stop it

- **Set `rel="noopener noreferrer"` on every anchor that opens a new tab.** `noopener` nullifies `window.opener`; `noreferrer` additionally suppresses the `Referer` header and implies `noopener` in all browsers that support it.
- **Pass `noopener,noreferrer` in the features string of `window.open()` calls.** The HTML attribute fix does not cover programmatic tab opens.
- **As a belt-and-suspenders measure for legacy code paths**, set `newWindow.opener = null` immediately after a `window.open()` call returns, before the target page can execute.
- **Enforce a `Referrer-Policy: no-referrer` response header** globally; this reduces data leakage even if the `opener` channel is somehow preserved.
- **Audit user-supplied or third-party link targets** before rendering them with `target="_blank"` — consider forcing all external links through a redirect interstitial that strips `opener` at the server side.
- **Rely on browser defaults cautiously.** Chromium ≥ 88 and Firefox ≥ 79 treat `target="_blank"` as implicitly `noopener`, but explicit attributes remain necessary for older clients, WebViews, and Electron shells that embed older engine versions.
- **Content Security Policy** does not directly prevent this attack; however, a strict `frame-ancestors` and `navigate-to` policy limits the blast radius if a redirect does occur.

In this project, see the defenses: [osionos](../defense/osionos/reverse-tabnabbing.md).

## References

- OWASP Community — Reverse Tabnabbing attack page: <https://owasp.org/www-community/attacks/Reverse_Tabnabbing>
- OWASP HTML5 Security Cheat Sheet (Tabnabbing): <https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html>
- MDN Web Docs — `rel="noopener"` (definition and browser compatibility): <https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Attributes/rel/noopener>
