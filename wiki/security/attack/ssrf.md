# Server-Side Request Forgery (SSRF)

> An attacker tricks the server into issuing HTTP (or other protocol) requests on their behalf, reaching internal infrastructure that is unreachable directly from the internet.

## What it is

SSRF arises when an application accepts a URL or network location from user-supplied input and then fetches that resource itself, server-side, without adequately restricting which destinations are permitted. Because the outbound request originates from the server's own network identity, it can bypass perimeter firewalls, reach private RFC-1918 address space, and carry any ambient credentials the server holds (IAM role tokens, internal API keys, cloud metadata). The attack class spans multiple transport layers: HTTP, HTTPS, `file://`, `gopher://`, and `dict://` are all realistic vectors. SSRF is listed in OWASP Top 10 2021 as a standalone category (A10) — its promotion from a secondary concern reflects how cloud-native architectures have made internal HTTP services the norm rather than the exception.

## How the attack works

1. **Locate a user-controlled URL parameter.** The attacker finds a feature that accepts a remote URL — webhook registration, image import, PDF renderer, link-preview generator, or URL-based OAuth callback.
2. **Substitute an internal target.** The attacker replaces the legitimate URL with a private address: a cloud metadata endpoint, a Kubernetes API server, an internal database with an HTTP interface, or simply `http://127.0.0.1:<port>/admin`.
3. **Server issues the request.** The application code performs an outbound HTTP call using the attacker-supplied value and returns (or partially returns) the response body to the attacker — directly in a response field, in an error message, or via a timing side-channel in a blind-SSRF variant.
4. **Credential or data extraction.** The attacker reads what the server fetched: an IAM role token from the cloud metadata service, a database dump endpoint, or an internal service's admin API.
5. **Pivot.** With a valid credential or an open internal port, the attacker issues further requests to deepen access into the private network.

**Illustrative (non-weaponized) example — blocked vs. allowed:**

```python
import urllib.request, urllib.parse

def fetch_preview(user_url: str) -> bytes:
    # VULNERABLE: no destination validation
    return urllib.request.urlopen(user_url).read()

# Attacker-supplied input that would reach the cloud metadata service:
# user_url = "http://169.254.169.254/latest/meta-data/iam/security-credentials/my-role"
```

A safe version validates `user_url` against an explicit allowlist of hostnames before any network I/O is performed. The call above never reaches the wire when the destination does not match a known-good external domain.

## Real-world impact

The most widely documented SSRF impact category involves cloud instance metadata services. OWASP's community attack reference notes that AWS's `http://169.254.169.254/` endpoint is a canonical SSRF target because it returns IAM role credentials in plaintext to any process running on the instance — no authentication required at the network layer. An attacker who can force the server to fetch that URL can exfiltrate temporary credentials and assume the attached IAM role, potentially gaining read/write access to S3 buckets, Secrets Manager entries, or other AWS services. This impact pattern, including exposure of configuration data and authentication material through metadata service abuse, is documented in the OWASP Server-Side Request Forgery community page.

Source: [OWASP — Server Side Request Forgery (attack page)](https://owasp.org/www-community/attacks/Server_Side_Request_Forgery)

## OWASP classification

SSRF appears as a dedicated top-level category in the **OWASP Top 10 2021 — A10: Server-Side Request Forgery**. The authoritative defensive reference is the OWASP Cheat Sheet for prevention, which covers allowlist architecture, network-layer controls, and response sanitization.

Reference: [SSRF Prevention — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)

## How defenders stop it

- **Strict allowlist, not blocklist.** Enumerate every legitimate external domain the application may fetch; reject anything else before a socket is opened. Blocklists (refusing `169.254.x.x`, `10.x`, `::1`, etc.) are bypassable through DNS rebinding, IPv6 encoding, and redirect chains.
- **Resolve DNS once, validate the IP, then connect.** Prevent TOCTOU bypass: resolve the hostname, check the resolved IP against the allowlist, and pass the IP (not the hostname) to the HTTP client so a second DNS lookup cannot return a different address.
- **Disable unnecessary URL schemes.** Restrict the HTTP client to `https://` only; explicitly block `file://`, `gopher://`, `dict://`, `ftp://`, and bare `http://` where not required.
- **Enforce response size and content-type limits.** Truncate or discard large responses; validate `Content-Type` against what is expected. This limits exfiltration volume and prevents metadata endpoint data from being relayed verbatim.
- **Run outbound fetch workers in a network-isolated context.** Place the fetch service in a DMZ or dedicated subnet with an egress firewall that blocks RFC-1918 ranges (`10/8`, `172.16/12`, `192.168/16`) and the link-local range (`169.254/16`). Cloud providers offer IMDSv2 (token-gated metadata) — enforce it via instance configuration.
- **Disable HTTP redirects or validate each hop.** If the HTTP client follows redirects, each intermediate URL must pass the same allowlist check; a redirect to an internal address re-opens the SSRF surface.
- **Log and alert on outbound requests to unexpected destinations.** Anomaly detection on egress traffic can surface successful or attempted SSRF that bypasses input validation.

In this project, see the defenses: [opposite-osiris](../defense/opposite-osiris/ssrf.md), [auth-gateway](../defense/auth-gateway/ssrf.md).

## References

- [SSRF Prevention — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [OWASP — Server Side Request Forgery (community attack page)](https://owasp.org/www-community/attacks/Server_Side_Request_Forgery)
