# Unauthorized Access / Privilege Escalation

> An attacker acts on resources or performs operations that the application's authorization model was designed to prohibit — either by accessing another user's data at the same trust level (horizontal escalation) or by reaching capabilities reserved for a more privileged role (vertical escalation).

## What it is

Broken access control describes the failure of an application to reliably enforce the boundaries between what each authenticated (or unauthenticated) principal is allowed to see or do. Authorization logic is conceptually separate from authentication: a system can correctly verify *who you are* while still failing to check *what you may do*. The gap arises when access decisions depend on client-supplied input that the server trusts without independent verification — a user ID embedded in a URL, a role flag stored in a cookie, a JWT claim the server never re-validates against a database of actual permissions. Unlike many vulnerability classes that require a memory corruption primitive or a protocol-level weakness, broken access control is exploitable with nothing more than a web browser and the ability to modify an HTTP request. It ranked first in the OWASP Top 10 for 2021, appearing in 94% of applications tested across the contributing dataset, with more than 318,000 documented instances.

## How the attack works

1. **Reconnaissance.** The attacker maps the application's endpoints and identifies parameters that appear to represent object identifiers — numeric record IDs in query strings, UUIDs in path segments, account numbers in form fields, or role flags in cookies and JWT payloads.
2. **Parameter manipulation.** The attacker substitutes their own identifier with a value belonging to a different account or a higher-privilege tier, then resubmits the request without modifying any other part of the session.
3. **Server-side authorization failure.** The backend code retrieves the record indicated by the attacker-supplied parameter without confirming that the requesting principal owns or is permitted to access it. The requested data or action is returned as though the request were legitimate.
4. **Lateral or vertical impact.** In a horizontal escalation the attacker reads or modifies another user's records. In a vertical escalation the attacker invokes an administrative endpoint that should be unreachable from their assigned role, potentially reading all records, deleting data, or issuing privileged operations on behalf of the system.

**Illustrative example — insecure direct object reference (IDOR) against a fictional invoicing API:**

```
# Conceptual pseudocode — not a working exploit; shown for educational clarity only

# Attacker is authenticated as user 1042 and holds a valid session token.
# They observe their own invoice is fetched at:
GET /api/invoices/8801  →  200 OK, returns invoice owned by user 1042

# Attacker increments the invoice ID without modifying the session:
GET /api/invoices/8802  →  200 OK, returns invoice owned by user 1099

# A correctly implemented server-side check would instead respond:
GET /api/invoices/8802  →  403 Forbidden
# because the session principal (1042) does not own invoice 8802.
```

The attack succeeds not because of any cryptographic weakness but because the server omits the ownership check entirely. The session token is valid; only the authorization decision is missing.

## Real-world impact

In June 2026, Brian Krebs reported that pro-Iranian threat actors hijacked a series of high-value Instagram accounts — including the official account of the Obama White House — by abusing Meta's AI customer-support chatbot during its password-reset workflow. The actors supplied an IP address geographically consistent with each target account and then manipulated the chatbot into linking a new, attacker-controlled email address to the existing account before the reset code was issued. Because the chatbot's workflow did not enforce ownership verification between the requesting session and the target account identifier, the adversary obtained a one-time reset code for accounts they did not own — a textbook access-control bypass at the workflow level. Accounts protected by multi-factor authentication resisted the takeover; those relying solely on the email-recovery path were compromised. Meta issued an emergency patch over the following weekend. The incident illustrates that access-control failures are not confined to REST parameters: any workflow that accepts an account identifier and acts on it without re-establishing authorization at each step carries the same structural risk. Source: [Krebs on Security, June 2026](https://krebsonsecurity.com/2026/06/hackers-used-metas-ai-support-bot-to-seize-instagram-accounts/).

## OWASP classification

This attack class is the top-ranked entry in the current OWASP Top 10: **A01:2021 — Broken Access Control**. Key mapped weaknesses include `CWE-862` (Missing Authorization), `CWE-639` (Authorization Bypass Through User-Controlled Key), and `CWE-285` (Improper Authorization). OWASP also maintains a dedicated cheat sheet covering policy design, enforcement placement, and testing methodology.

- [A01:2021 — Broken Access Control — OWASP Top 10](https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/)
- [Authorization Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)

## How defenders stop it

- **Enforce authorization on the server, never the client.** Access decisions must be made in trusted server-side code. Client-supplied role flags, account IDs in cookies, or `isAdmin` JWT claims must be verified against the authoritative permission store on every request, not assumed correct.
- **Default to deny.** Every endpoint should require an explicit grant; missing policy should resolve to rejection, not pass-through.
- **Verify ownership on every object access.** When a request references a resource by ID, the server must confirm that the session principal is entitled to that specific record — not merely that the principal is authenticated.
- **Implement role-based and attribute-based access control (RBAC / ABAC) at the data layer.** Use row-level security in the database (e.g., PostgreSQL RLS policies) so that even a compromised application layer cannot return rows belonging to another tenant.
- **Avoid exposing predictable object identifiers** where possible; use non-sequential UUIDs. This raises the bar for enumeration but is not a substitute for server-side authorization checks.
- **Restrict HTTP methods.** If an endpoint is read-only, reject `POST`, `PUT`, `PATCH`, and `DELETE` at the gateway level rather than relying on application-layer intent.
- **Log and alert on access-control rejections.** A spike in `403` responses from a single session or IP is a strong signal of active enumeration; treat it as an incident trigger.
- **Test authorization with automated tooling.** Use tools such as Burp Suite with the Autorize extension or OWASP ZAP's authorization scanner to verify that every endpoint rejects cross-account and cross-role requests, not just unauthenticated ones.
- **Apply the principle of least privilege throughout the stack.** Service accounts, API keys, and database users should hold only the permissions needed for their specific function; a compromised component should not be able to escalate through over-provisioned credentials.

In this project, see the defenses: [grobase](../defense/grobase/broken-access-control.md), [osionos](../defense/osionos/broken-access-control.md), [osionos-bridge](../defense/osionos-bridge/broken-access-control.md), [mail-calendar](../defense/mail-calendar/broken-access-control.md), [platform](../defense/platform/broken-access-control.md).

## References

- OWASP Top 10:2021 A01 — Broken Access Control: <https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/>
- OWASP Authorization Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html>
- OWASP WSTG — Testing for Bypassing Authorization Schema (WSTG-ATHZ-02): <https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/05-Authorization_Testing/02-Testing_for_Bypassing_Authorization_Schema>
- Krebs on Security — "Hackers Used Meta's AI Support Bot to Seize Instagram Accounts" (June 2026): <https://krebsonsecurity.com/2026/06/hackers-used-metas-ai-support-bot-to-seize-instagram-accounts/>
