# Audit Logging and Monitoring — grobase (the BaaS backend)

> grobase emits a structured, tamper-resistant audit trail that captures authorization denials on the Rust data plane, WAF anomalies at the edge, and sensitive authentication events in a service-role-only PostgreSQL table — giving operators the signal they need to detect and investigate abuse.

## What it is (the concept)

**Audit logging** is the practice of recording security-relevant events in a **durable, structured, append-only log** that is separate from ordinary application output and protected against tampering by unprivileged actors. **Monitoring** is the operational layer that consumes that log to detect anomalies in real time or for post-incident forensics. Together they close the feedback loop required by defense-in-depth: controls that block attacks must also surface evidence that an attack was attempted, so defenders can respond.

## What it defends against

See [Security Logging and Monitoring Failures (A09:2021)](../../attack/audit-logging-monitoring.md).

In the grobase context the threat is threefold: a tenant silently probing API key scopes to discover which operations are permitted, a rate-limited attacker varying request cadence to evade the token-bucket gate, and a compromised account where the absence of a login-failure trail prevents investigators from reconstructing the timeline. Without a monitorable record of these events, every other control in the stack produces no forensic signal.

## How grobase implements it

Three independent mechanisms together provide coverage from the PostgreSQL row level up to the WAF edge.

**1. Structured Rust tracing calls on the data-plane bypass path**

`apps/grobase/src/data-plane-router/crates/data-plane-server/src/routes/bypass_auth.rs` defines two audited error paths that sit directly in the live request handlers:

```rust
// scope_denied — L179–185
tracing::warn!(
    target: "audit",
    event = "scope_denied",
    tenant = %id.tenant_id,
    surface = %surface,
    "api key lacks '{missing}' scope (403)"
);

// bypass_ratelimit — L206–213
tracing::warn!(
    target: "audit",
    event = "rate_limited",
    tenant = %tenant,
    surface = %surface,
    rps,
    "tenant exceeded package rate limit (429)"
);
```

Both emit to the named tracing target `"audit"`, carrying structured fields (`tenant`, `surface`, `rps`) that a downstream subscriber can filter and forward independently of general application logs. `scope_denied` fires on every 403 from the op-gate; `bypass_ratelimit` fires on every 429 from the schema, DDL, and graph handlers.

**2. ModSecurity relevant-only audit logging with Kong correlation-id propagation**

`apps/grobase/infra/docker/services/waf/conf/modsecurity.conf` configures the WAF to write a structured audit entry for every anomalous transaction:

```
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLog /var/log/modsecurity/modsec_audit.log
SecAuditLogParts ABCFHZ
```

`RelevantOnly` keeps the log focused on 4xx (excluding 404) and 5xx responses — the population that contains real attacks and WAF rule hits — while suppressing noise from benign traffic. `ABCFHZ` parts capture the request headers, request body, response headers, audit log trailer, and matched rule details, providing rule-attributed entries.

`apps/grobase/infra/docker/services/kong/conf/kong.yml` adds a global correlation-id plugin (lines 57–61):

```yaml
- name: correlation-id
  config:
    header_name: X-Request-ID
    generator: uuid#counter
    echo_downstream: true
```

Every request entering Kong receives a unique `X-Request-ID` that is echoed to the client and forwarded upstream, making it possible to join a WAF audit entry with the Kong access log and the upstream service log for a single request.

**3. Tamper-resistant PostgreSQL authentication audit log via a SECURITY DEFINER RPC**

`models/auth-security-migration.sql` (lines 88–167) defines `auth_record_audit_event`, a `SECURITY DEFINER` function with a locked `search_path`:

```sql
CREATE OR REPLACE FUNCTION auth_record_audit_event(
    event_type TEXT, email TEXT DEFAULT NULL, details JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
...
  IF event_type NOT IN (
    'login_success', 'login_failed', 'password_recovery_requested',
    'refresh_success', 'refresh_failed', 'mfa_totp_verified',
    'ip_shift_detected', ...  -- full allowlist enforced; unknown type → RAISE EXCEPTION
  ) THEN
    RAISE EXCEPTION 'Unsupported audit event type' USING ERRCODE = '22023';
  END IF;
  INSERT INTO auth_audit_events (event_type, user_id, email, ip_address, user_agent, details)
  VALUES (
    event_type, matched_user_id, normalized_email,
    COALESCE(current_setting('request.header.x-forwarded-for', true),
             current_setting('request.header.x-real-ip', true)),
    current_setting('request.header.user-agent', true),
    COALESCE(details, '{}'::jsonb)
  ) ...
```

The table is access-controlled at lines 159–167:

```sql
ALTER TABLE auth_audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY auth_audit_events_no_public_access ON auth_audit_events
    FOR SELECT TO authenticated USING (false);
REVOKE ALL ON auth_audit_events FROM anon, authenticated;
GRANT INSERT, SELECT ON auth_audit_events TO service_role;
REVOKE EXECUTE ON FUNCTION auth_record_audit_event(...) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_record_audit_event(...) TO service_role;
```

The `SECURITY DEFINER` + `SET search_path = public` pairing prevents search-path injection. The allowlist means no caller can inject an arbitrary event type string. The deny-all RLS `SELECT` policy means no `authenticated` role session can read the audit trail even with direct table access — only `service_role` can query it.

## How we know it is applied

**Data-plane audit calls:** the `scope_denied` and `bypass_ratelimit` functions are not aspirational — they are the actual return sites for the 403 and 429 responses in `bypass_auth.rs`. Every schema, DDL, and graph handler in the live binary calls `bypass_ratelimit` before executing; the auth middleware calls `scope_denied` before returning a 403.

**WAF and Kong config:** both `modsecurity.conf` and `kong.yml` are baked into their respective Docker build contexts and are applied at container start with no runtime override. The m140 gate (`apps/grobase/scripts/verify/m140-network-controls.sh`) exercises ARM A against the live `mini-baas-waf` container, probes with known-malicious payloads, and — per the script header — optionally confirms rule IDs in the ModSecurity audit log output. The gate description (line 21–30) states:

```
# ARM A — OWASP-CRS WAF as the sole public listener (Supabase OSS has NONE):
#     the public WAF each return HTTP 403 from the OWASP CRS (real status read
#     off the wire). Optionally confirmed against the ModSecurity audit log rule IDs.
```

**Auth audit migration:** `apps/grobase/scripts/db/apply-project-sql.sh` line 46 applies the migration unconditionally on every boot:

```sh
$psql_base -f /project-init/03-auth-security.sql
```

This is not a one-time migration gate — it re-applies the idempotent `CREATE OR REPLACE FUNCTION` and the RLS policy on every container start, ensuring the access-control posture is always current.

## Reference

The [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) establishes the canonical design vocabulary for this control: what events merit recording, how to structure log entries for machine consumption, and how to protect logs from tampering. grobase's three-layer implementation maps directly onto those recommendations — structured fields over free-form strings, a named audit target distinct from the application log, database-level access control on the log store, and a correlation mechanism (X-Request-ID) to join entries across layers.

## Residual risk / assumptions

- **Rust tracing subscriber dependency.** The `tracing::warn!(target: "audit", ...)` calls produce events only if the deployed tracing subscriber is configured to capture the `"audit"` target at `WARN` level or below. If the subscriber silently drops `"audit"` events (e.g. a filter that only captures `"info"` target), the data-plane audit trail disappears at runtime with no compile-time error. There is no CI gate that asserts the subscriber is wired to emit `"audit"` events to a durable sink.
- **ModSecurity audit log retention and forwarding.** The WAF writes to `/var/log/modsecurity/modsec_audit.log` inside the container. Unless that path is mounted to a persistent volume or forwarded to a log aggregator, the audit log is lost on container restart. The current compose configuration does not mandate such a mount.
- **Auth audit event coverage.** The `auth_record_audit_event` allowlist covers authentication events but not data-mutation events (table writes, schema changes). Authorization denials on the data plane are covered by the Rust tracing path, not by this PostgreSQL function; the two trails are not joined by a common correlation ID.
- **No alerting layer.** The stack emits audit signals but ships no out-of-box alerting rule or SIEM integration. Detection of anomalies (e.g. high `scope_denied` rate from one tenant) requires the operator to configure a log-aggregation pipeline and alerting thresholds outside of grobase.
