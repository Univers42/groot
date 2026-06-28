# Session Hijacking / Session Fixation

> An attacker obtains or pre-sets a victim's session token to impersonate them as an authenticated user, bypassing credential checks entirely.

## What it is

Session tokens are the proof-of-identity issued by a server after a user logs in; every subsequent request carries that token so the server does not re-challenge credentials. Session hijacking occurs when an attacker captures a *legitimately issued* token — through network sniffing, cross-site scripting, or malware — and replays it to act as the victim. Session fixation is a related but distinct attack where the adversary *plants* a known token *before* authentication, so that when the victim logs in the server elevates the attacker-controlled token rather than generating a fresh one. Both techniques give the attacker an authenticated session without ever knowing the victim's password. The weakness is not in password strength but in how tokens are generated, transmitted, and invalidated.

## How the attack works

### Session Hijacking

1. The attacker identifies a target application that transmits session cookies over HTTP (no TLS) or reflects the session token in URLs.
2. The attacker intercepts traffic — on a shared Wi-Fi network, via a man-in-the-middle proxy, or through a malicious browser extension — and extracts the `Set-Cookie` header containing the session identifier.
3. The attacker injects that token into their own browser (e.g., via developer tools or a cookie editor) and sends a request; the server sees a valid token and grants full access.
4. The legitimate user's session continues in parallel; the server cannot distinguish the two clients because both present the same token.

### Session Fixation

1. The attacker opens an unauthenticated session on the target application, receiving a session ID such as `sid=abc123`.
2. The attacker crafts a link that forces the victim's browser to adopt that same ID, for example:
   ```
   https://example.com/login?sid=abc123
   ```
   or by injecting a `Set-Cookie` header via a reflected XSS payload:
   ```html
   <script>document.cookie = "sid=abc123; path=/"</script>
   ```
3. The victim clicks the link and authenticates normally.
4. The server — failing to regenerate the session ID on login — upgrades `abc123` to an authenticated state.
5. The attacker, who already holds `abc123`, now possesses an authenticated session without ever logging in.

### Illustrative, non-working snippet

The following shows the *server-side anti-pattern* that enables fixation — a login handler that does **not** rotate the session ID:

```python
# VULNERABLE — do not deploy
def login(request):
    user = authenticate(request.POST["username"], request.POST["password"])
    if user:
        request.session["user_id"] = user.id
        # BUG: existing session ID is reused; attacker who planted it now owns an auth'd session
        return redirect("/dashboard")
```

The correct pattern calls the framework's session-regeneration API immediately after a successful credential check, invalidating the old token and issuing a new one.

## Real-world impact

A widely documented class of session-hijacking attacks exploits insecure session cookies on networks where TLS is absent or stripped. The 2010 release of the Firesheep browser extension demonstrated at scale that session tokens for major consumer platforms were transmitted over plain HTTP on shared Wi-Fi, allowing any user on the same network to clone authenticated sessions with one click. The incident forced multiple large platforms to enable HTTPS by default across all authenticated pages — a practice now considered baseline hygiene. The underlying vulnerability was not a flaw in any individual codebase but rather the systematic failure to bind sessions to an encrypted channel. OWASP classifies this behaviour under Broken Authentication (A07:2021), noting that exposing session identifiers in unencrypted traffic or URLs is a top contributing factor to account takeover at scale. See: [OWASP A2:2017 – Broken Authentication](https://owasp.org/www-project-top-ten/2017/A2_2017-Broken_Authentication).

## OWASP classification

- **Cheat Sheet:** [Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) — the authoritative reference covering token generation entropy, cookie attributes, lifecycle management, and regeneration requirements.
- **Attack reference:** [OWASP Community — Session Fixation](https://owasp.org/www-community/attacks/Session_fixation) — defines the fixation sub-class and distinguishes it from post-authentication hijacking.
- **Top Ten mapping:** A07:2021 – Identification and Authentication Failures (formerly A2:2017 – Broken Authentication); CWE-384 (Session Fixation), CWE-287 (Improper Authentication).

## How defenders stop it

- **Regenerate session IDs on privilege change.** Issue a brand-new, cryptographically random token immediately after login, sudo re-authentication, or any privilege escalation. Never promote a pre-existing token.
- **Use high-entropy tokens.** Session IDs must be generated from a CSPRNG with at least 128 bits of entropy; sequential or timestamp-derived IDs are predictable.
- **Set `Secure`, `HttpOnly`, and `SameSite` cookie attributes.** `Secure` prevents transmission over HTTP; `HttpOnly` blocks JavaScript access; `SameSite=Lax` or `Strict` limits cross-site delivery.
- **Enforce TLS everywhere.** Never transmit session tokens over plaintext connections; use HSTS to prevent downgrade attacks.
- **Never expose tokens in URLs.** URL-embedded session IDs appear in server logs, browser history, and `Referer` headers, multiplying exposure surface.
- **Implement idle and absolute timeouts.** Short idle timeouts bound the window in which a stolen token remains useful; absolute timeouts force re-authentication regardless of activity.
- **Invalidate server-side on logout.** Delete or expire the token record on the server at logout; a client-side cookie deletion alone is insufficient because the server still honours the ID if replayed.
- **Bind sessions to TLS channel or client fingerprint where appropriate.** Token binding or secondary checks (e.g., IP family, user-agent prefix) raise the bar for remote replay, though they are not substitutes for the above controls.

In this project, see the defenses: [grobase](../defense/grobase/session-management.md), [osionos](../defense/osionos/session-management.md), [osionos-bridge](../defense/osionos-bridge/session-management.md), [opposite-osiris](../defense/opposite-osiris/session-management.md), [auth-gateway](../defense/auth-gateway/session-management.md), [mail-calendar](../defense/mail-calendar/session-management.md).

## References

- OWASP — Session Management Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html>
- OWASP — Session Fixation attack description: <https://owasp.org/www-community/attacks/Session_fixation>
- OWASP — A2:2017 Broken Authentication (CWE-384, CWE-287): <https://owasp.org/www-project-top-ten/2017/A2_2017-Broken_Authentication>
