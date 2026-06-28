# Cross-Tenant Data Leakage

> When a tenant in a multi-tenant system can read, write, or enumerate data that belongs to a different tenant because the isolation boundary between them is absent, incomplete, or bypassable.

## What it is

A multi-tenant system serves multiple independent customers (tenants) from a single shared deployment — one database cluster, one object store, one API surface. Isolation is the guarantee that each tenant's data, sessions, and compute are invisible to every other tenant. Cross-tenant data leakage is the failure mode where that guarantee breaks down: one tenant's authenticated requests resolve records, files, or metadata owned by another tenant. The break can originate at any layer — a missing `tenant_id` filter in a SQL query, an IDOR-vulnerable REST endpoint, an over-permissive caching key, a shared secret incorrectly scoped to a workspace instead of a tenant, or a misconfigured storage bucket ACL. Because every tenant shares the same code path, a single unfixed gap exposes not one account but potentially every account on the platform simultaneously. The vulnerability is distinct from ordinary broken access control because the victim and the attacker are both legitimate, authenticated users of the system — the attacker simply should not be able to see the victim's data.

## How the attack works

A realistic exploitation sequence, using a REST API as the vehicle:

1. **Authenticate as a legitimate tenant.** The attacker signs up for or already holds a valid account (`tenant_id = T-42`) and obtains a session token.
2. **Identify a resource identifier.** The attacker calls a normal endpoint — for example `GET /api/workspaces/8819/documents` — and records the numeric document IDs returned (`doc_id = 8819`).
3. **Probe neighboring identifiers.** Because IDs are sequential or guessable, the attacker increments or decrements the ID: `GET /api/documents/8820`. If the server verifies the session token but does not verify that document 8820 belongs to `tenant_id = T-42`, it returns data belonging to a different tenant.
4. **Automate enumeration.** A simple loop over a range of IDs harvests records across every tenant stored in the system, bounded only by the attacker's patience and the server's rate limits (if any exist).
5. **Escalate if write access is open.** The same pattern applied to `PUT /api/documents/8820` may allow the attacker to modify or delete another tenant's data, turning a read vulnerability into sabotage.

**Illustrative non-working snippet — the vulnerable pattern:**

```python
# BAD: session proves identity but query is not scoped to the caller's tenant
@app.get("/api/documents/{doc_id}")
def get_document(doc_id: int, current_user: User = Depends(auth)):
    return db.query("SELECT * FROM documents WHERE id = %s", doc_id)
```

```python
# CORRECT: every query is anchored to the authenticated tenant
@app.get("/api/documents/{doc_id}")
def get_document(doc_id: int, current_user: User = Depends(auth)):
    return db.query(
        "SELECT * FROM documents WHERE id = %s AND tenant_id = %s",
        doc_id, current_user.tenant_id
    )
```

The corrected form adds a mandatory `tenant_id` predicate so that even a valid `doc_id` belonging to another tenant returns no rows for the requesting user.

## Real-world impact

Isolation failures in shared cloud infrastructure have caused data exposure at scale. The 2019 Capital One breach — documented by Brian Krebs shortly after disclosure — illustrates what happens when resource boundaries are not enforced at the infrastructure layer: a misconfigured WAF role on AWS granted its bearer access to S3 buckets that should have been isolated to a specific service, ultimately exposing data for roughly 100 million customers. The mechanism (a cloud IAM role scoped too broadly, combined with an SSRF entry point) is structurally analogous to an application-layer cross-tenant leak: an identity was authenticated but not constrained to only its own data scope. At the SaaS application layer, OWASP documents that IDOR-class vulnerabilities — the direct mechanism behind most cross-tenant leakage — consistently rank among the most commonly exploited in real applications, and that the impact when triggered in a multi-tenant context is proportionally larger because one query flaw exposes data across the entire customer base, not just a single account. (Source: [Krebs on Security, August 2019](https://krebsonsecurity.com/2019/08/what-we-can-learn-from-the-capital-one-hack/))

## OWASP classification

OWASP addresses the multi-tenant isolation problem directly in the **Multi-Tenant Application Security Cheat Sheet**, which covers tenant separation at the data, compute, and network layers, including required controls for query scoping, session isolation, and storage partitioning.

Reference: [OWASP Multi-Tenant Application Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html)

The underlying access-control failure also maps to **OWASP API Security Top 10 — API1:2023 Broken Object Level Authorization (BOLA)**, which specifically calls out endpoints that accept object identifiers without verifying the caller's ownership of the referenced object.

## How defenders stop it

- **Enforce `tenant_id` at the query layer, not the application layer.** Every database query, ORM scope, and stored procedure must carry a `tenant_id` predicate. Row-Level Security (RLS) policies in PostgreSQL push this enforcement into the database itself, so an application-layer slip cannot bypass it.
- **Never expose raw sequential or predictable internal IDs to clients.** Use UUIDs or opaque tokens as external identifiers; sequential integers invite enumeration.
- **Validate ownership on every mutable operation.** `GET`, `PUT`, `PATCH`, and `DELETE` handlers must each confirm that the target resource's `tenant_id` matches the authenticated caller's tenant, not just that the resource exists.
- **Scope storage ACLs to individual tenant prefixes.** Object stores (S3, GCS, Azure Blob) must use per-tenant bucket paths or separate buckets, with IAM policies that deny cross-prefix reads even for service accounts.
- **Apply least-privilege to service-to-service credentials.** Internal service roles should be scoped to the minimum set of resources they legitimately touch; a role that can list all tenants' data is a latent cross-tenant leak waiting for an SSRF or misconfiguration.
- **Cache keys must include `tenant_id`.** Shared caches (Redis, Memcached, CDN) keyed only on resource ID will serve one tenant's cached response to another tenant requesting the same ID.
- **Rate-limit and log enumeration patterns.** Sequential ID probing produces a detectable access pattern; alerting on rapid sequential resource requests by a single identity is a compensating control while structural fixes are deployed.
- **Integration-test cross-tenant access in CI.** Spin up two test tenant fixtures and assert that each tenant's authenticated requests return 403/404 for all of the other tenant's resources — not just the happy path.

In this project, see the defenses: [grobase](../defense/grobase/multi-tenancy-isolation.md), [osionos-bridge](../defense/osionos-bridge/multi-tenancy-isolation.md), [platform](../defense/platform/multi-tenancy-isolation.md).

## References

- [OWASP Multi-Tenant Application Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html)
- [OWASP API Security Top 10 — API1:2023 Broken Object Level Authorization](https://owasp.org/www-project-api-security/)
- [Krebs on Security — "What We Can Learn from the Capital One Hack" (August 2, 2019)](https://krebsonsecurity.com/2019/08/what-we-can-learn-from-the-capital-one-hack/)
