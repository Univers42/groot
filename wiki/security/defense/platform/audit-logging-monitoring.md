# Audit Logging and Monitoring — platform / infrastructure (cross-cutting)

> The platform maintains a tamper-resistant, deny-all-to-clients authentication audit log that records every sensitive auth event — including failed logins, IP shifts, MFA enrolment, and bot-challenge failures — with IP address, user-agent, and a 13-month retention directive, enforced at the database layer via Row Level Security and a `SECURITY DEFINER` function callable only by `service_role`.

## What it is (the concept)

**Audit logging** is the systematic, append-only recording of security-relevant events with sufficient context (who, what, when, from where) to enable forensic investigation and anomaly detection after an incident. **Tamper resistance** is achieved by denying all client-side reads and writes through **Row Level Security (RLS)** and role-scoped grants: only the privileged `service_role` can insert or select rows. A **`SECURITY DEFINER` function** — executing with the owner's privileges regardless of the caller's role — is the sole write path, which ensures the event type is validated against a closed **`CHECK` constraint** before any row lands in the table.

## What it defends against

See [Security Logging and Monitoring Failures (A09:2021)](../../attack/audit-logging-monitoring.md).

Without a forensic trail, account compromise and brute-force campaigns go undetected until after significant damage. In this application's context, an attacker who successfully guesses a password, bypasses the Cloudflare Turnstile bot challenge, or hijacks a session from a different IP would leave no evidence in a system without audit logging. The `ip_shift_detected` event type in particular is designed to surface session-hijacking indicators automatically.

## How the platform implements it

**`models/auth-security-migration.sql`** is the single authoritative migration that provisions every component of this control:

**The `auth_audit_events` table** (lines 9–41) records `event_type`, `user_id`, `email`, `ip_address`, `user_agent`, `details` (JSONB), and `created_at`. The `event_type` column carries a `CHECK` constraint enumerating every permitted event name — `login_success`, `login_failed`, `login_turnstile_failed`, `register_turnstile_failed`, `recover_turnstile_failed`, `password_changed`, `refresh_success`, `refresh_failed`, `logout`, `mfa_totp_enroll_started`, `mfa_totp_verified`, `webauthn_challenge_started`, `ip_shift_detected`, and others — so the database itself rejects any unknown event type at the storage layer, not just in application code. The constraint is subsequently widened (lines 46–84) to add email-flow and osionos-bridge event types via `ALTER TABLE … DROP CONSTRAINT … ADD CONSTRAINT`.

**Retention directive** (line 86):
```sql
COMMENT ON TABLE auth_audit_events IS 'security_monitoring: sensitive authentication events, …; retain for 13 months unless a documented legal hold applies.';
```

**`auth_record_audit_event()` SECURITY DEFINER function** (lines 88–157) is the exclusive write path. It validates the event type against the same closed list before inserting, resolves the caller's email to an internal `user_id`, and captures network context directly from PostgREST request headers:
```sql
COALESCE(
  current_setting('request.header.x-forwarded-for', true),
  current_setting('request.header.x-real-ip', true)
)
```
The user-agent is captured via `current_setting('request.header.user-agent', true)`. Because the function runs as `SECURITY DEFINER`, it writes to `auth_audit_events` even though the calling role (`service_role`) would be blocked by RLS on a direct insert.

**RLS and grants** (lines 159–167) complete the tamper-resistance boundary:
```sql
ALTER TABLE auth_audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY auth_audit_events_no_public_access ON auth_audit_events
  FOR SELECT TO authenticated USING (false);
REVOKE ALL ON auth_audit_events FROM anon, authenticated;
GRANT INSERT, SELECT ON auth_audit_events TO service_role;
REVOKE EXECUTE ON FUNCTION auth_record_audit_event(TEXT, TEXT, JSONB) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_record_audit_event(TEXT, TEXT, JSONB) TO service_role;
```
Client roles (`anon`, `authenticated`) have zero access to the table and cannot invoke the write function — eliminating any possibility of client-side log injection or log reading.

Two compound indexes (lines 43–44) make forensic queries efficient:
```sql
CREATE INDEX IF NOT EXISTS auth_audit_events_event_created_idx ON auth_audit_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS auth_audit_events_email_created_idx ON auth_audit_events (lower(email), created_at DESC);
```

## How we know it is applied

**`apps/grobase/scripts/db/apply-project-sql.sh`** applies `03-auth-security.sql` (which maps to `auth-security-migration.sql`) unconditionally on every container startup — not under a one-time marker guard — so the idempotent `CREATE OR REPLACE` and `IF NOT EXISTS` clauses converge on every boot:

```sh
$psql_base -f /project-init/03-auth-security.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_auth_security') ON CONFLICT DO NOTHING"
```

Lines 46–47 of that script run outside the `schema_applied` guard that wraps the other migrations, meaning the auth-security migration is re-applied and the marker is re-inserted (idempotently via `ON CONFLICT DO NOTHING`) on every container launch — guaranteeing the RLS policy and function are always in place even after a Postgres volume restore.

## Reference

The [Logging Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) establishes the principle that security-relevant events must be recorded with sufficient context (who, what, when, from where) and protected from modification or deletion by the entities whose actions are being recorded. This implementation satisfies both requirements: IP and user-agent are captured in-database from request headers (eliminating application-layer tampering), and RLS plus role grants prevent any authenticated session from reading or writing audit rows directly.

## Residual risk / assumptions

- **No alerting pipeline.** The table captures events but there is no automated alert on successive `login_failed` rows or a `login_turnstile_failed` spike. Detection is retrospective unless an operator queries `auth_audit_events` manually or wires an external monitoring consumer to the `service_role`-accessible table.
- **PostgREST header forwarding.** IP capture relies on `current_setting('request.header.x-forwarded-for', true)` being correctly populated by PostgREST, which in turn depends on the Kong gateway forwarding the original client IP. A misconfigured or absent `X-Forwarded-For` header results in a `NULL` `ip_address` in the audit row — events are still recorded, but without network attribution.
- **No log-shipping or off-box backup.** Audit rows live only in the PostgreSQL instance. A volume loss or deliberate database deletion destroys the audit history. Shipping to an append-only external store (e.g. S3, Loki) is not wired.
- **`service_role` key is a trust boundary.** Any process holding the `service_role` JWT (e.g., the auth gateway) can call `auth_record_audit_event` and therefore insert arbitrary audit rows. Spoofed or omitted events are only preventable if every code path that should emit an event actually does so — this is a code-discipline assumption, not a database-enforced one.
- **13-month retention is advisory.** The `COMMENT` directive documents the intent; no automated partition drop or archival job enforces it on a schedule.
