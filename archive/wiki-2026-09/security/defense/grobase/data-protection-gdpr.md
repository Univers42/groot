# GDPR Data Protection — grobase (the BaaS backend)

> grobase enforces GDPR right-to-erasure by irreversibly anonymising every identifiable field on a user record and purging all linked sessions and tokens through a privilege-locked, SECURITY DEFINER stored routine, while storing one-time tokens exclusively as SHA-256 hex digests so that a database breach never yields reversible credentials.

## What it is (the concept)

**GDPR right-to-erasure** (Article 17) requires that a controller permanently remove or irrecoverably anonymise a data subject's **personally identifiable information (PII)** when a valid deletion request is verified. Complementary to erasure, **pseudonymisation** and **one-way hashing** ensure that derivative data (audit logs, issued tokens) cannot be re-linked to the original identity once the primary record is overwritten. **Data retention policies** impose time-bounded storage limits on each category of personal data so that data is not held longer than its legal basis permits.

## What it defends against

See [Sensitive Data Exposure / GDPR non-compliance](../../attack/data-protection-gdpr.md).

In the grobase context the specific threats are: (1) a database breach exposing cleartext one-time tokens (password-reset, email-verification) that can be replayed or reverse-mapped to users; (2) PII persisting indefinitely after an erasure request, creating regulatory liability and ongoing exposure surface; (3) activity-log rows retaining IP addresses, device strings, and geolocation beyond the legally permitted window.

## How grobase implements it

### SHA-256 token hashing — `models/gdpr-migration.sql` lines 405–411

Every one-time token is stored as a hex SHA-256 digest via `gdpr_hash_token`, a deterministic, `IMMUTABLE` SQL function with no secret ingredient (used for lookup equality, not as an HMAC):

```sql
CREATE OR REPLACE FUNCTION gdpr_hash_token(raw_token TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(digest(COALESCE(raw_token, ''), 'sha256'), 'hex')
$$;
```

The raw token is issued to the user over TLS and never stored; only the digest lives in `user_tokens`.

### Irreversible anonymisation — `models/gdpr-migration.sql` lines 413–454

`anonymise_user(target_user_id INT)` runs as `SECURITY DEFINER SET search_path = public`, which pins the execution context so no caller-side search-path manipulation can redirect the function. When called it:

- Overwrites `email` → `anonymised_<id>@deleted.invalid`, `username` → `deleted_<id>`, `password_hash` → `'deleted'`, and nulls `first_name`, `last_name`, `avatar_url`, `bio`.
- Strips the JSON keys `ip`, `device`, `location`, `user_agent`, `browser`, `os` from every `user_activities` row for that user and appends `{"anonymised": true}`.
- Issues `DELETE FROM sessions WHERE user_id = target_user_id` and `DELETE FROM user_tokens WHERE user_id = target_user_id`, removing all active sessions and any remaining token digests.

### Retention-policy declarations — `models/gdpr-migration.sql` lines 334–340

Each PII-bearing table carries a machine-readable `COMMENT ON TABLE` retention policy, e.g.:

```sql
COMMENT ON TABLE user_activities IS 'data_retention_policy: security and activity logs,
  including IP addresses and device strings, must be purged or anonymised after 13 months
  per CNIL log-retention guidance unless a documented legal hold applies.';
```

`users`, `user_tokens`, `sessions`, `user_consents`, `gdpr_requests`, and `newsletter_optins` each carry analogous declarations, making the intended retention horizon explicit at the schema level.

## How we know it is applied

**Boot-time wiring:** `apps/grobase/scripts/db/apply-project-sql.sh` line 42 applies the migration as the second initialisation script on every fresh database start:

```bash
$psql_base -f /project-init/02-gdpr.sql
```

**Privilege lockdown — live, not aspirational:** `models/rls-hardening-migration.sql` lines 44–46 execute a targeted `REVOKE` that makes `anonymise_user` uncallable by any API-level role:

```sql
-- anonymise_user: destructive — callable by NO API role.
IF to_regprocedure('public.anonymise_user(integer)') IS NOT NULL THEN
  REVOKE EXECUTE ON FUNCTION public.anonymise_user(integer) FROM anon, authenticated;
END IF;
```

Only the `service_role` key (server-side, never exposed to the browser) retains implicit superuser access, ensuring that no authenticated end-user request can invoke erasure arbitrarily. The same block (`rls-hardening-migration.sql` lines 54–64) grants `gdpr_request_deletion()`, `gdpr_export_my_data()`, and related safe RPCs to `authenticated` only, so the self-service GDPR API surface is both locked down and intentionally exposed.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/) addresses the failure mode where sensitive data is stored or transmitted without adequate protection — including one-way tokens kept in cleartext and PII retained beyond its legitimate purpose. grobase's token-hashing and anonymisation controls directly mitigate the "storing passwords using weak or trivially reversible algorithms" and "sensitive data in cleartext at rest" sub-cases that OWASP A02 enumerates.

Corroborating standard: GDPR Article 17 (Right to erasure / "right to be forgotten") and Recital 65 specify that personal data must be erased without undue delay when the legal basis for processing no longer exists — the 30-day window declared in grobase's table comments reflects this obligation.

## Residual risk / assumptions

- `gdpr_hash_token` uses a bare SHA-256 with no HMAC key or salt. Token uniqueness relies entirely on the entropy of the raw token issued to the user; a low-entropy token (e.g., a short numeric code) would be vulnerable to offline dictionary attack against the digest. The implementation assumes the upstream generator (the auth layer) produces cryptographically random values.
- The retention-policy `COMMENT ON TABLE` declarations are documentation metadata only. No automated purge job is wired in this migration; 13-month activity-log purges and 30-day token sweeps depend on an external cron or the `restore-if-empty` snapshot pipeline respecting these windows — they are not self-enforcing.
- `anonymise_user` can only be triggered via `service_role`; there is no automated pipeline that calls it immediately upon a verified GDPR request. A human or service-role process must consume the `gdpr_requests` queue and invoke the function within the 30-day SLA.
- The control covers the grobase PostgreSQL layer. Any PII replicated to external sinks (search indices, analytics pipelines, third-party error trackers) falls outside the scope of this migration and must be managed separately.
