# Man-in-the-Middle & Protocol Downgrade

> An attack class in which an adversary secretly interposes between two communicating parties to intercept, read, or alter traffic — often by coercing the connection into a weaker cryptographic protocol that the attacker can then break or bypass.

## What it is

Transport layer attacks exploit weaknesses in how clients and servers negotiate an encrypted channel. In a man-in-the-middle (MitM) attack, the adversary positions themselves between client and server — on the same network segment, through DNS or BGP hijacking, or via a rogue access point — and relays traffic in both directions while silently reading or modifying it. A protocol downgrade attack is a specific sub-technique: the attacker interferes with the TLS handshake to convince one or both parties to fall back to an older, cryptographically weaker version of the protocol (e.g., TLS 1.0, SSLv3, or even SSLv2) that the attacker has the means to decrypt or exploit. Because TLS 1.0, 1.1, SSLv2, and SSLv3 are formally deprecated, any server still offering these versions extends an unnecessary attack surface. Downgrade attacks are especially insidious because neither the client nor the server necessarily detects that the negotiated version is weaker than both sides would ordinarily accept, and the connection appears valid to application code throughout.

## How the attack works

1. **Gain a network position.** The attacker achieves adjacency: ARP spoofing on a local segment, a rogue Wi-Fi access point, DNS cache poisoning, or a BGP prefix hijack. Any of these routes the victim's packets through the attacker's host before they reach the legitimate server.

2. **Intercept the TLS ClientHello.** The attacker's proxy receives the client's initial handshake message, which advertises the TLS versions and cipher suites the client supports.

3. **Manipulate the version negotiation.** In a downgrade attack, the proxy strips or suppresses higher-version records and forwards a degraded `ClientHello` to the server — or responds to the client with a `ServerHello` that selects an obsolete protocol. Without a downgrade-prevention mechanism such as the `TLS_FALLBACK_SCSV` sentinel value, both sides may accept the weaker version without warning.

4. **Exploit the weakened session.** Against SSLv3, for example, the POODLE technique exploits CBC padding oracle behaviour to decrypt session cookies one byte at a time. Against export-grade cipher suites (FREAK, Logjam), the attacker factors the short key offline in minutes. Once plaintext is recovered, session tokens, credentials, and sensitive payloads are exposed.

5. **Forward traffic transparently.** The attacker re-encrypts traffic toward the legitimate server, keeping the connection alive. Both parties observe a working HTTPS session; neither sees an error.

**Illustrative (non-weaponized) example — what a misconfigured server looks like versus a hardened one:**

```nginx
# UNSAFE — accepts obsolete protocol versions and weak cipher suites
ssl_protocols SSLv3 TLSv1 TLSv1.1 TLSv1.2;
ssl_ciphers "ALL:!aNULL:!eNULL";

# SAFE — restricts to modern versions; uses only AEAD suites with forward secrecy
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
ssl_prefer_server_ciphers off;
```

In the unsafe configuration a downgrade-capable client or an interposing proxy can negotiate SSLv3 or TLSv1.0. The hardened configuration removes these from the offer entirely, so no negotiation can produce them.

## Real-world impact

The POODLE vulnerability (CVE-2014-3566), disclosed in October 2014 by a Google security team, demonstrated a practical downgrade path from TLS to SSLv3 followed by a padding oracle attack against CBC-mode encryption. Any website that still served SSLv3 — and many did at the time, including high-traffic banking and e-commerce properties — was vulnerable to an active attacker on the same network recovering authenticated session cookies, leading to account takeover without any credential theft. The OWASP Web Security Testing Guide (WSTG-CRYP-01) catalogues this attack alongside BEAST (TLSv1.0 CBC), CRIME (TLS compression), DROWN (SSLv2), and Logjam (weak DHE keys) as a documented class of TLS downgrade exploitation, noting that "many of these attacks require a (usually active) MitM attack, and significant resources."

Source: [OWASP WSTG-CRYP-01 — Testing for Weak Transport Layer Security](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/09-Testing_for_Weak_Cryptography/01-Testing_for_Weak_Transport_Layer_Security)

## OWASP classification

MitM and protocol downgrade attacks fall under **OWASP A02:2021 — Cryptographic Failures** (previously "Sensitive Data Exposure"), which covers cases where data in transit is inadequately protected due to weak or absent encryption. The primary technical guidance is the **Transport Layer Security Cheat Sheet**, which mandates disabling TLS 1.0 and 1.1, requiring TLS 1.2 or 1.3 with AEAD cipher suites, deploying `TLS_FALLBACK_SCSV` to block negotiated downgrades, and enforcing HSTS to prevent initial plaintext contact.

Reference: [OWASP Transport Layer Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)

## How defenders stop it

- **Disable obsolete protocol versions** — remove SSLv2, SSLv3, TLSv1.0, and TLSv1.1 from the server's offer; only TLS 1.2 and TLS 1.3 should be negotiable.
- **Enforce AEAD-only cipher suites** — prefer `ECDHE-*-AES*-GCM` and `ECDHE-*-CHACHA20-POLY1305`; disable null, export, RC4, and static RSA suites which lack forward secrecy.
- **Send `TLS_FALLBACK_SCSV`** — this sentinel value in the `ClientHello` tells a compliant server to abort if a lower version than its maximum is negotiated, blocking active downgrade manipulation.
- **Deploy HTTP Strict Transport Security (HSTS)** — the `Strict-Transport-Security` response header with a long `max-age` and `includeSubDomains` instructs browsers to refuse any HTTP connection to the domain, eliminating the plaintext first-request window that `sslstrip`-style tools exploit.
- **Add to the HSTS preload list** — submitting the domain to `hstspreload.org` bakes the HSTS policy into browser binaries, protecting first-time visitors before they receive a server response.
- **Use OCSP stapling** — attach a timestamped certificate status proof to the TLS handshake so clients can validate revocation without a third-party lookup that itself could be intercepted.
- **Pin or constrain certificate issuance with CAA DNS records** — `CAA` resource records name the certificate authorities permitted to issue for the domain, reducing the blast radius of a compromised CA being used to issue a fraudulent certificate enabling MitM.
- **Require mutual TLS (mTLS) for internal service-to-service calls** — both sides authenticate their certificates, preventing an internal MitM from impersonating either endpoint.
- **Keep TLS libraries patched** — OpenSSL, BoringSSL, and equivalent libraries ship periodic fixes for newly discovered padding oracles, timing channels, and state-machine bugs; unpatched versions reintroduce known-downgrade surface even with a clean configuration.

In this project, see the defenses: [grobase](../defense/grobase/transport-security-tls.md), [opposite-osiris](../defense/opposite-osiris/transport-security-tls.md), [auth-gateway](../defense/auth-gateway/transport-security-tls.md), [platform](../defense/platform/transport-security-tls.md).

## References

- [OWASP Transport Layer Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)
- [OWASP HTTP Strict Transport Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Strict_Transport_Security_Cheat_Sheet.html)
- [OWASP WSTG-CRYP-01 — Testing for Weak Transport Layer Security](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/09-Testing_for_Weak_Cryptography/01-Testing_for_Weak_Transport_Layer_Security)
