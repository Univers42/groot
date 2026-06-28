# Privilege Escalation via Trust-Boundary Crossing

> An attacker abuses an implicit or misconfigured trust relationship between two system zones to gain rights, roles, or data access that their legitimate identity does not authorise.

## What it is

Every non-trivial system is divided into security zones — a public API tier, an authenticated service layer, an admin plane, an internal database network. A trust boundary is the demarcation line where data crosses from one zone into another with a different privilege level or identity context. When a component on the higher-trust side of that line acts on input it received from a lower-trust side without re-validating the caller's actual authority, an attacker can craft that input to claim a privilege they were never granted. This is privilege escalation via trust-boundary crossing: the system's own internal trust structure becomes the attack surface. The vulnerability is not inherently about broken cryptography or missing patches — it is an architectural flaw where the enforcement of access decisions is placed on the wrong side of a boundary, or skipped entirely when data moves between zones. Both vertical escalation (gaining a higher role, such as user-to-admin) and horizontal escalation (accessing a peer's resources without acting as them) arise from the same root cause.

## How the attack works

1. **Reconnaissance — map the trust topology.** The attacker identifies where the application's components trust each other without re-challenging identity: a backend microservice that trusts a header injected by a gateway, an internal API that whitelists a subnet rather than verifying a signed token, a batch job that inherits the service-account permissions of its host rather than a scoped credential.

2. **Identify the crossing point.** A request, message, or file must cross the trust boundary carrying some representation of the caller's identity or role — a JWT claim, a query parameter, a cookie field, a Protobuf field, a database column value written by a less-privileged path.

3. **Manipulate the identity representation.** The attacker tampers with whichever artifact carries the privilege signal on the lower-trust side before it crosses the boundary. The higher-trust receiver does not re-verify it against an authoritative source.

4. **Execute under the escalated privilege.** The higher-trust component acts on the forged or stolen signal — reading restricted rows, invoking an admin endpoint, minting a session token for a different user, or writing to a protected resource.

5. **Persist or pivot.** Once inside the higher-trust zone the attacker can issue secondary requests that appear entirely legitimate to downstream components, because those components see only the internal, already-trusted traffic.

**Illustrative (non-weaponised) example.** An internal workspace API sits behind an API gateway. The gateway authenticates the user and forwards a custom header `X-Internal-Role: member`. The internal service trusts that header unconditionally because it assumes only the gateway can reach it. A developer misconfigures a load-balancer rule and the internal service becomes reachable from the DMZ. An attacker sends a direct request with `X-Internal-Role: admin` and receives a response with full administrative data. No credentials were stolen; the trust boundary was simply unguarded on its inbound face.

```http
# Attacker's direct request to the internal service (not routed via gateway)
GET /admin/users HTTP/1.1
Host: internal-api.svc.local
X-Internal-Role: admin
X-Forwarded-For: 10.0.0.1
```

The fix is not to block the header — it is to verify the caller's identity inside the receiving service with a cryptographically verifiable credential (a signed JWT, mutual TLS, or a short-lived service token), regardless of network position.

## Real-world impact

The 2019 Capital One breach illustrates the class of impact that trust-boundary confusion enables at scale. A server-side request forgery vulnerability allowed an attacker to query the AWS EC2 Instance Metadata Service (IMDS) from within the application tier. The IMDS is an internal AWS endpoint that operates at the trust level of the instance itself — it returns IAM role credentials to any process running on that machine. The application server was granted an IAM role with excessive S3 permissions, and because IMDS responses are authoritative within the AWS trust model, the attacker received valid, temporary AWS credentials that crossed the boundary between the application zone and the cloud-control plane. The result was the extraction of over 100 million customer records. The root causes were a misconfigured WAF (the initial entry point), an overly permissive IAM role (excessive trust granted at the boundary), and the absence of IMDSv2 enforcement (no re-authentication required at the metadata boundary). The Federal Reserve and OCC attributed regulatory sanctions in part to the inadequacy of access controls at internal trust boundaries. Source: [The Hacker News — Capital One breach coverage](https://thehackernews.com/2019/07/capital-one-data-breach.html) and subsequent SEC filings.

## OWASP classification

This attack class maps directly to the **Elevation of Privilege** threat in the STRIDE model and to **A01:2021 — Broken Access Control**, the top-ranked vulnerability category in the OWASP Top Ten. The OWASP Threat Modeling Cheat Sheet defines trust boundaries as the primary locations at which threats materialise, and explicitly cites JWT role tampering as the canonical Elevation of Privilege example. The OWASP Web Security Testing Guide section on privilege escalation (WSTG-ATHZ-03) further classifies the techniques — hidden-field manipulation, parameter injection, IP-header spoofing — used to cross trust boundaries in practice.

- OWASP Threat Modeling Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html>
- OWASP Authorization Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html>
- OWASP WSTG — Privilege Escalation (WSTG-ATHZ-03): <https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/05-Authorization_Testing/03-Testing_for_Privilege_Escalation>

## How defenders stop it

- **Never trust what crosses a boundary — re-verify.** Every service must authenticate the caller using a cryptographically verifiable credential (signed JWT with issuer/audience validation, mTLS client certificate, short-lived OIDC token) regardless of which network segment the request arrives from. Network position is not identity.
- **Apply least privilege at every crossing point.** IAM roles, service accounts, and database users must hold only the permissions needed for their specific function. Overly permissive service identities turn any boundary crossing into a high-impact event.
- **Deny by default; grant explicitly.** Access decisions should default to denial and require explicit, auditable grants — not implicit inheritance of ambient trust from the surrounding environment.
- **Validate role and scope claims server-side on every request.** Client-supplied or header-supplied role claims must be cross-checked against an authoritative store (token introspection endpoint, session server, or database row) — never accepted at face value.
- **Enforce boundary hardening in the network layer as defence-in-depth, not as the primary control.** Network policies and firewall rules reduce attack surface but cannot substitute for in-process verification — as the Capital One breach demonstrated, any single misconfiguration collapses purely perimeter-based trust.
- **Log every privilege transition** — any event where a request crosses a trust boundary at an elevated role should be auditable, alertable, and rate-limited.
- **Use IMDSv2 (or equivalent re-authentication mechanisms) on cloud metadata endpoints** to prevent SSRF-driven credential harvesting from the cloud control plane.
- **Rotate and scope service credentials.** Short-lived credentials limit the blast radius when a boundary crossing is exploited.

In this project, see the defenses: [grobase](../defense/grobase/trust-boundary.md), [osionos-bridge](../defense/osionos-bridge/trust-boundary.md), [opposite-osiris](../defense/opposite-osiris/trust-boundary.md), [auth-gateway](../defense/auth-gateway/trust-boundary.md).

## References

- OWASP Threat Modeling Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html>
- OWASP Authorization Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html>
- OWASP WSTG-ATHZ-03: Testing for Privilege Escalation — <https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/05-Authorization_Testing/03-Testing_for_Privilege_Escalation>
- OWASP Top Ten A01:2021 — Broken Access Control — <https://owasp.org/Top10/A01_2021-Broken_Access_Control/>
- The Hacker News — Capital One breach (July 2019) — <https://thehackernews.com/2019/07/capital-one-data-breach.html>
