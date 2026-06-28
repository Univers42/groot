# Clickjacking (UI Redress Attack)

> An attacker overlays invisible or disguised interface elements on top of a legitimate page, causing a user's intended click to silently trigger an action on a hidden, attacker-controlled frame.

## What it is

Clickjacking is a client-side deception technique in which a malicious page embeds a target site inside a transparent `<iframe>`, then positions that invisible frame over decoy content. Because the browser renders the iframe with the victim's active session, any click the user lands on the decoy is actually delivered to the underlying target. The technique exploits the browser's same-origin rendering model: the embedding page cannot read the frame's content, but it can still receive the user's interaction. The attack vector is purely visual — no network interception or code injection on the target server is required. Because the victim's own authenticated session performs every action, server-side audit logs record a legitimate request with no obvious anomaly.

## How the attack works

1. **Attacker crafts a lure page.** A visually convincing page (a fake prize claim, a viral video, a survey) is hosted on an attacker-controlled domain.
2. **Target is embedded invisibly.** The lure page includes the target site — for example, a social-media "post" button or a banking "confirm transfer" screen — in a zero-opacity `<iframe>` sized and positioned to overlap an enticing button on the lure page.
3. **Victim visits the lure page.** Because the victim is already authenticated on the target site, the iframe renders that site's full session context.
4. **Click is hijacked.** The victim clicks what appears to be "Play video" on the lure; the event is actually received by the invisible iframe and activates the target's action button.
5. **Action completes silently.** The target server processes the request as a legitimate, authenticated action. The victim sees only the lure page reacting.

**Illustrative example — invisible "Send money" overlay:**

```html
<!-- Attacker's lure page (simplified, illustrative only) -->
<style>
  #trap-frame {
    opacity: 0;
    position: absolute;
    top: 140px;      /* aligned so the iframe's "Confirm" button sits under */
    left: 220px;     /* the lure's "Watch now" button */
    width: 400px;
    height: 200px;
    z-index: 10;
    pointer-events: auto;
  }
  #decoy-button {
    position: absolute;
    top: 140px;
    left: 220px;
    z-index: 5;
  }
</style>

<button id="decoy-button">▶ Watch now</button>

<!-- iframe targets a fictional payments page; real attacks use a live authenticated session -->
<iframe id="trap-frame"
        src="https://example-bank.invalid/transfer?to=attacker&amount=500">
</iframe>
```

*This snippet is illustrative. The target URL is intentionally fictional (`*.invalid`). Never replicate this against a real site or session.*

## Real-world impact

One of the most-cited early incidents occurred in 2008, when researchers demonstrated that Adobe Flash's plugin-settings page — which controlled microphone and camera permissions — could be loaded inside a hidden iframe on any web page. A user clicking what appeared to be an innocent game element on the attacker's page was in reality toggling Flash's "always allow" permission for the attacker's domain, silently granting access to the device camera and microphone. Shortly afterward, similar techniques were applied to social-media platforms: Twitter and Facebook both suffered clickjacking campaigns in which users unknowingly reposted content or "liked" attacker-chosen pages, enabling rapid viral propagation purely through deceptive clicks. These incidents forced browser vendors and standards bodies to accelerate adoption of frame-busting headers. Source: [OWASP — Clickjacking Attack](https://owasp.org/www-community/attacks/Clickjacking).

## OWASP classification

Clickjacking does not map to a single OWASP Top 10 entry because it is a cross-cutting technique rather than a vulnerability class of its own; it typically exploits misconfigured or absent security headers (aligning with **A05:2021 — Security Misconfiguration**). The authoritative guidance is the **OWASP Clickjacking Defense Cheat Sheet**:

- [https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html)

## How defenders stop it

- **`Content-Security-Policy: frame-ancestors`** — the modern, CSP-level control. Set `frame-ancestors 'none'` to forbid all embedding, or `frame-ancestors 'self'` to allow only same-origin frames. Takes precedence over `X-Frame-Options` in browsers that support CSP Level 2+.
- **`X-Frame-Options`** — the legacy header (`DENY` or `SAMEORIGIN`). Still required for older browsers; safe to send alongside `frame-ancestors`.
- **`SameSite` cookie attribute** — setting session cookies to `SameSite=Lax` or `SameSite=Strict` prevents the browser from sending them in cross-site iframe contexts, breaking the attack's dependence on an existing authenticated session.
- **Frame-busting JavaScript** — a defensive fallback (`if (top !== self) top.location = self.location`) that forces a page out of any enclosing frame. Fragile on its own (can be defeated with `sandbox` iframe attributes), but provides defence-in-depth when headers are misconfigured.
- **Sensitive-action confirmation dialogs** — for high-impact operations (fund transfers, permission grants, account deletion), a secondary challenge (re-auth prompt, CAPTCHA, or TOTP) that cannot be pre-positioned breaks the single-click hijack model.
- **Subresource Integrity and nonce-based CSP** — reduces attacker ability to load auxiliary scripts that assist in overlay positioning.

In this project, see the defenses: [opposite-osiris](../defense/opposite-osiris/clickjacking.md), [mail-calendar](../defense/mail-calendar/clickjacking.md), [platform](../defense/platform/clickjacking.md).

## References

- OWASP Clickjacking Defense Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html
- OWASP Community — Clickjacking Attack — https://owasp.org/www-community/attacks/Clickjacking
