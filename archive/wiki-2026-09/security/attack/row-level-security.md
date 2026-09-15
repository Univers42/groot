# Horizontal Privilege Escalation / Cross-Tenant Data Leakage

> An attacker authenticated as one tenant or user manipulates queries or identifiers to read or write rows that the data model was designed to confine to a different tenant or user — bypassing isolation that the application assumed the database would enforce on its behalf.

## What it is

Row-level security (RLS) is a database-layer control that filters the rows a given principal can see or modify based on a policy evaluated at query time. Horizontal privilege escalation through RLS bypass occurs when those policies are absent, misconfigured, or silently circumvented — allowing one authenticated user to reach data that belongs exclusively to another user or tenant in the same database. The attack is "horizontal" because the aggressor does not gain elevated role permissions; they stay at the same privilege tier while crossing a logical ownership boundary. In multi-tenant SaaS architectures this boundary is structural: every tenant's records typically co-exist in shared tables, separated only by a `tenant_id` column and whatever policy guards it. When that guard fails — either because it was never applied, because the application supplies the wrong context variable, or because the policy logic contains a logical gap — every record in the table is potentially reachable by any authenticated session. The OWASP Database Security Cheat Sheet identifies row-level permissions as a required control for security-critical applications, alongside table-level and column-level restrictions.

## How the attack works

1. **Authentication as a legitimate tenant.** The attacker creates or obtains a valid account in the application. No special privileges are needed — a free-tier account is sufficient.
2. **Observation of identifiers.** The attacker inspects API responses, URL parameters, WebSocket messages, or client-side state to identify object references tied to their own tenant context: record IDs, workspace slugs, document UUIDs, or similar tokens.
3. **Context injection or substitution.** The attacker modifies a request — changing a path segment, a JSON body field, a GraphQL variable, or a custom HTTP header — to reference an identifier that belongs to a different tenant. In some systems the attack is subtler: the attacker supplies a crafted JWT or session cookie that sets a `tenant_id` claim to an arbitrary value, which the application then passes directly into a database query as the RLS context variable.
4. **Policy gap exploitation.** If no row-level policy exists, or if the policy was written for table `A` but the query joins through table `B` where no policy is active, the database returns rows belonging to the target tenant without any error.
5. **Exfiltration or mutation.** The attacker reads sensitive records (personal data, financial figures, credentials, internal messages) or — if the endpoint allows writes — modifies or deletes another tenant's data.

**Illustrative example — misconfigured RLS on a shared `documents` table (fictional schema, educational only):**

```sql
-- Intended policy: each session can only see its own tenant's rows.
-- A developer adds RLS to the 'documents' table ...
CREATE POLICY tenant_isolation ON documents
  USING (tenant_id = current_setting('app.current_tenant')::uuid);

-- ... but forgets to enable RLS on the table itself.
-- ALTER TABLE documents ENABLE ROW LEVEL SECURITY;  <-- missing line

-- Without that statement the policy is defined but never evaluated.
-- Every authenticated session can issue:
SELECT * FROM documents WHERE id = '<target_uuid>';
-- and receive rows from any tenant.
```

A complementary application-layer failure occurs when the backend reads `tenant_id` from a client-supplied request body rather than from the verified server-side session, letting an attacker write an arbitrary UUID into the parameter and shift the database context to a victim tenant.

## Real-world impact

Multi-tenant SaaS platforms have repeatedly suffered data leakage through broken tenant isolation, often traced to missing or incorrectly applied row-level controls. The OWASP Top 10 (2021) lists Broken Access Control — the category that subsumes both IDOR and cross-tenant leakage — as the single most prevalent vulnerability class, found in 94 % of applications sampled during that research cycle, with more than 318,000 documented instances. OWASP further notes that attackers can exploit this class by manipulating a primary key to "view or edit someone else's account," which maps directly to the tenant-ID substitution pattern described above. Although individual SaaS breach disclosures frequently omit RLS specifics for legal reasons, the documented pattern is consistent: a shared-table architecture with per-row ownership metadata but no enforced database-level policy, combined with a server endpoint that trusts client-supplied tenant identifiers. The consequence is wholesale exposure of every other tenant's rows to any authenticated session. OWASP documents this impact category as unauthorized disclosure of sensitive information and unauthorized modification or destruction of data, both of which trigger regulatory obligations under frameworks such as GDPR and HIPAA.

Source: [OWASP Top 10:2021 — A01 Broken Access Control](https://owasp.org/www-project-top-ten/) and [OWASP IDOR Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Insecure_Direct_Object_Reference_Prevention_Cheat_Sheet.html).

## OWASP classification

This attack falls under **Broken Access Control (A01:2021)** in the OWASP Top Ten, which encompasses missing authorization checks, insecure direct object references, and cross-tenant data access. At the database layer, the OWASP Database Security Cheat Sheet prescribes row-level permissions as a mandatory control, and recommends blocking direct table access in favour of restricted views as a secondary barrier.

- Primary reference: [OWASP Database Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html)
- Supporting reference: [OWASP IDOR Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Insecure_Direct_Object_Reference_Prevention_Cheat_Sheet.html)

## How defenders stop it

- **Enable RLS at the table level before defining policies.** The `ALTER TABLE … ENABLE ROW LEVEL SECURITY` statement must be issued; a policy defined on a table without RLS enabled is silently inert.
- **Apply `FORCE ROW LEVEL SECURITY`** on tables where even the table owner's sessions must be subject to policy — this closes the bypass path available to superuser-equivalent application roles.
- **Set the tenant context from a trusted source only.** The `app.current_tenant` (or equivalent) configuration parameter must be derived from the verified server-side session, never from a client-supplied value such as a request header, URL parameter, or JWT claim that the application has not independently validated.
- **Write policies that cover every access path.** A policy on a base table does not automatically extend to views, foreign-table joins, or materialized views that reference it. Audit every query path that touches tenant-scoped tables.
- **Use `USING` and `WITH CHECK` clauses together.** `USING` governs reads; `WITH CHECK` governs writes. Omitting `WITH CHECK` leaves insert and update operations unguarded even when read isolation is correct.
- **Test RLS in isolation from application logic.** Execute raw SQL as the restricted role to verify that cross-tenant queries return zero rows, not an error the application might swallow silently.
- **Block direct table access.** Route all application queries through restricted database views or stored procedures that embed the ownership predicate, treating RLS as a defence-in-depth layer rather than the sole control.
- **Validate at the application layer too.** Before passing an object identifier to the database, confirm server-side that the authenticated session's `tenant_id` matches the ownership record for that object. RLS and application-layer checks are complementary, not interchangeable.
- **Audit with privilege-escalation test cases.** Include test scenarios where a session authenticated as tenant A attempts to read or write rows owned by tenant B; any non-403 response is a policy gap.

In this project, see the defenses: [grobase](../defense/grobase/row-level-security.md), [platform](../defense/platform/row-level-security.md).

## References

- [OWASP Database Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html)
- [OWASP IDOR Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Insecure_Direct_Object_Reference_Prevention_Cheat_Sheet.html)
- [OWASP Top 10:2021 — A01 Broken Access Control](https://owasp.org/www-project-top-ten/)
