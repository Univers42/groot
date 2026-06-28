# Defense in Depth — grobase (the BaaS backend)

> Privileged SQL functions are isolated at two independent layers — locked execution context and revoked public execute — so neither a search_path hijack nor an unauthenticated caller can escalate through definer-rights routines.

## What it is (the concept)

**Defense in depth** is the practice of stacking independent security controls so that defeating any one layer leaves the remaining layers intact. Each control is self-sufficient; together they close a larger attack surface than any single measure could. In the database context, the key vocabulary is **SECURITY DEFINER** (a function that runs with the privileges of its *owner*, not the caller) and **search_path hijacking** (an attacker prepending a schema they control so that a call inside the definer function resolves to a shadowed, attacker-supplied object). A **REVOKE … FROM PUBLIC** grant strips the default execute permission before it can be exploited.

## What it defends against

See [Multi-Stage Intrusion / Layered Attack](../../attack/defense-in-depth.md).

In grobase the risk is concrete: the Kong anon API key is public by design, PostgREST forwards unauthenticated requests to Postgres, and SECURITY DEFINER functions run as the schema owner. Without explicit hardening, any caller who can reach PostgREST can invoke a privileged RPC, and any function whose search_path is not locked can be redirected mid-execution to attacker-controlled objects. A single failure in either the caller-filter or the execution context would give an unauthenticated HTTP request owner-level write access.

## How grobase implements it

Two complementary controls are applied in sequence.

**Layer 1 — locked execution context (`SET search_path = public`).**
[`models/gdpr-migration.sql`](../../../../models/gdpr-migration.sql) declares `anonymise_user` with an explicit path lock:

```sql
CREATE OR REPLACE FUNCTION anonymise_user(target_user_id INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public   -- line 417: execution context pinned; shadowing impossible
```

This pins every name resolution inside the function to the `public` schema, so no caller-set `search_path` value can shadow a called function or operator.

**Layer 2 — revoked PUBLIC execute.**
[`models/osionos-bridge-migration.sql`](../../../../models/osionos-bridge-migration.sql) declares the workspace RPCs as SECURITY DEFINER and immediately strips the default grant:

```sql
$$ LANGUAGE SQL STABLE SECURITY DEFINER;                                          -- line 341
REVOKE ALL ON FUNCTION public.osionos_bridge_list_workspaces(UUID, UUID[]) FROM PUBLIC;  -- line 343
GRANT EXECUTE ON FUNCTION public.osionos_bridge_list_workspaces(UUID, UUID[]) TO service_role; -- line 344
```

The same pattern follows for `osionos_bridge_upsert_workspace` at lines 455–456. No authenticated or anon role inherits execute; only the service role key can invoke these.

**Layer 3 — systematic re-hardening migration (runs last).**
[`models/rls-hardening-migration.sql`](../../../../models/rls-hardening-migration.sql) closes any gap from the two individual files by iterating every named SECDEF function and revoking PUBLIC as a single atomic batch (lines 27–40):

```sql
FOR fn IN
  SELECT p.oid::regprocedure AS sig
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    'anonymise_user','auth_record_audit_event','gdpr_export_my_data',
    'gdpr_request_deletion','gdpr_set_newsletter','gdpr_withdraw_consent',
    'gdpr_submit_request','gdpr_request_newsletter_optin','gdpr_confirm_newsletter_optin')
LOOP
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.sig);
END LOOP;
```

Lines 42–68 then re-grant only the intended verbs per role: `anonymise_user` to no API role (destructive, service-internal only); `auth_record_audit_event` to `service_role`; `gdpr_*` user-facing functions to `anon` or `authenticated` as appropriate. The file header (line 10) states the rationale directly: *"Postgres RLS + grants are the ONLY data wall."*

## How we know it is applied

`apps/grobase/scripts/db/apply-project-sql.sh` wires the three files in numbered order on every boot:

```bash
$psql_base -f /project-init/02-gdpr.sql          # line 42 — anonymise_user + locked search_path
$psql_base -f /project-init/04-osionos-bridge.sql # line 49 — bridge RPCs + first REVOKE FROM PUBLIC
$psql_base -f /project-init/07-rls-hardening.sql  # line 69 — systematic REVOKE + final grant table
```

The `07` suffix guarantees the hardening migration executes after both schema files, so its grants are final and cannot be overwritten by a later file. The script is idempotent (`CREATE OR REPLACE`, existence-guarded `DO $$` blocks) and runs on every container start, not only on first provision.

## Reference

The OWASP Secure Product Design Cheat Sheet (https://cheatsheetseries.owasp.org/cheatsheets/Secure_Product_Design_Cheat_Sheet.html) articulates the principle that security must be designed into architecture from the start, not retrofitted. Applying it here means the database privilege model is enforced by the schema itself — independently of any application-layer check — so a misconfigured proxy or a bypassed middleware cannot alone grant unauthorized access. The PostgreSQL `SECURITY DEFINER` section of the official documentation (https://www.postgresql.org/docs/current/sql-createfunction.html) specifies that `SET search_path` is the correct and only reliable mechanism to prevent search_path hijacking in definer-rights functions.

## Residual risk / assumptions

- The `osionos_bridge_list_workspaces` and `osionos_bridge_upsert_workspace` functions use `SECURITY DEFINER` without an explicit `SET search_path = public` clause; their protection relies entirely on the REVOKE FROM PUBLIC layer. If a future change accidentally grants execute to a broad role before the hardening migration runs, the search_path vector reopens on those two functions.
- The hardening migration is only as complete as its enumerated function list. A new SECURITY DEFINER function added without a matching entry in `rls-hardening-migration.sql` will inherit PUBLIC execute until the list is updated.
- The control operates at the Postgres grant layer. It does not defend against a compromised `service_role` credential: anything presenting the service key bypasses all role-level restrictions by design.
- Kong's anon apikey exposure is acknowledged in the migration comment (line 4): no Kong ACL plugin covers `/rest/v1`, so Postgres is the only enforcement boundary. Any Kong misconfiguration that opens a route to a SECDEF function would require both this and the RLS layer to fail simultaneously before data is exposed.
