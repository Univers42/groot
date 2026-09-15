# GDPR Data-Subject Rights — platform / infrastructure (cross-cutting)

> The platform installs a consent ledger and a suite of SECURITY DEFINER RPCs at bootstrap that guarantee every data-subject right (access, erasure, withdrawal, retention) is enforceable directly at the database layer, independently of any application tier.

## What it is (the concept)

**Data-subject rights** are the GDPR obligations that allow an individual to request access to, correction of, or erasure of their personal data, and to withdraw consent at any time. **Privacy by design** means these rights are not delegated to ad-hoc application code but are encoded as immutable, audited database functions with explicit retention windows. **Anonymisation** is the irreversible removal of all linkable PII, turning a row into a non-personal record. **Consent evidence** is the legally required proof — with timestamp, IP address, and policy version — that a subject actively granted a specific processing purpose.

## What it defends against

See [Sensitive Data Exposure](../../attack/data-protection-gdpr.md). In this stack the concrete threat is indefinite retention of personally identifiable information (email, IP, device string, activity log) without a legal basis, or the inability to honor a deletion or withdrawal request within the GDPR-mandated 30-day window. Both failures expose the operator to CNIL enforcement and civil liability.

## How platform implements it

**`models/gdpr-migration.sql`** is the single migration that installs the entire GDPR surface:

- **`pgcrypto` extension** (line 9):
  ```sql
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
  ```
  Enables `digest()` for SHA-256 token hashing (`gdpr_hash_token`), ensuring no raw confirmation token is persisted.

- **`user_consents` table** (lines 290-303): records each consent grant with forensic evidence:
  ```sql
  ip_at_consent VARCHAR(255),
  user_agent_at_consent VARCHAR(1024),
  version VARCHAR(32) NOT NULL,
  UNIQUE (user_id, consent_type, version)
  ```
  The `(user_id, consent_type, version)` uniqueness constraint prevents duplicate ledger entries per policy version.

- **Per-table `data_retention_policy` COMMENTs** (lines 334-340): machine-readable retention anchors on every sensitive table:
  ```sql
  COMMENT ON TABLE user_activities IS 'data_retention_policy: security and activity logs,
    including IP addresses and device strings, must be purged or anonymised after 13 months
    per CNIL log-retention guidance unless a documented legal hold applies.';
  COMMENT ON TABLE user_consents IS 'data_retention_policy: consent evidence is retained
    for the account lifetime and normally 5 years after withdrawal or closure.';
  ```

- **`anonymise_user(target_user_id INT)` SECURITY DEFINER** (lines 413-454): the erasure primitive. It overwrites all PII fields unconditionally, then scrubs every linked activity-log entry of its `ip`, `device`, `location`, `user_agent`, `browser`, and `os` keys, and hard-deletes all sessions and tokens:
  ```sql
  email = 'anonymised_' || id || '@deleted.invalid',
  username = 'deleted_' || id,
  password_hash = 'deleted',
  first_name = NULL, last_name = NULL, avatar_url = NULL, bio = NULL
  ```

- **`gdpr_export_my_data()` SECURITY DEFINER** (lines 456-484): assembles the Article 20 portability export, stripping `password_hash` from the user row and `token`/`session_token` from token and session rows before returning the JSONB payload. Identity is resolved from the JWT claim (`gdpr_require_authenticated_user()`), not from a caller-supplied parameter, so cross-user export is structurally impossible.

- **`gdpr_request_deletion()` SECURITY DEFINER** (lines 486-516): logs a deletion request in `gdpr_requests` with a computed `due_at = CURRENT_TIMESTAMP + gdpr_response_deadline()`, creating the 30-day compliance window. Soft-deletion is the first step; `anonymise_user` follows after the retention window.

- **`gdpr_withdraw_consent(consent_type TEXT)` SECURITY DEFINER** (lines 518-549): sets `granted = FALSE` and records `withdrawn_at`, then inserts a corroborating row in `gdpr_requests` so the withdrawal is auditable. The type is validated against `gdpr_allowed_consent_types()` before any write.

- **`newsletter_optins` table** (lines 317-330): double opt-in flow — a `token_hash` (SHA-256 of the raw token) is stored, never the raw token; confirmation sets `confirmed_at` and the token expires after 24 hours.

## How we know it is applied

`apps/grobase/scripts/db/apply-project-sql.sh` runs the GDPR migration idempotently at every stack bootstrap, guarded by a marker-table check so it executes exactly once per fresh database:

```sh
schema_applied=$($psql_base -Atc \
  "SELECT 1 FROM track_binocle_runtime_migrations WHERE marker = '${marker}_schema' LIMIT 1")
if [ "$schema_applied" != "1" ]; then
  $psql_base -f /project-init/01-user.sql
  $psql_base -f /project-init/02-gdpr.sql
  $psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_schema') ON CONFLICT DO NOTHING"
fi
```

(lines 39-44 of `apps/grobase/scripts/db/apply-project-sql.sh`)

After the migration, the script tightens grants in a separate inline block (lines 55-65), revoking blanket table access and limiting the `authenticated` role to the specific columns required — `user_consents`, `user_activities`, `sessions`, and `user_tokens` are fully revoked from `anon`. The RLS hardening pass (`07-rls-hardening.sql`) then runs as the final word.

## Reference

**A02 Cryptographic Failures — OWASP Top 10:2021**: <https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/>

OWASP A02 extends beyond encryption to cover any failure to protect sensitive data at rest, in transit, or in processing pipelines — including storing PII longer than necessary or failing to provide a deletion path. The GDPR controls here address the data-lifecycle dimension of A02: PII that cannot be erased or is retained beyond its legal window is, by definition, inadequately protected regardless of the encryption applied to it.

## Residual risk / assumptions

- **No automated purge job.** The retention-policy COMMENTs declare the windows; the `anonymise_user` function and `gdpr_request_deletion` create the legal trigger. A scheduled job that actually calls `anonymise_user` on rows whose `deletion_requested_at + 30 days` has elapsed does not exist in this repo. Erasure remains operator-initiated.
- **Application-tier enforcement.** The RPCs enforce identity via `gdpr_require_authenticated_user()`, which reads the JWT claim injected by PostgREST. A direct psql connection with `service_role` credentials bypasses all of this. The SECURITY DEFINER attribute limits privilege escalation within the schema but does not substitute for network-layer access control on the Postgres port.
- **CSV export not implemented.** `gdpr_export_my_data` returns machine-readable JSONB and notes in the payload that CSV export is planned for a future iteration. This may not satisfy a data-subject who requests a human-readable format.
- **Legal holds not implemented.** The COMMENTs document the legal-hold exception; no table or function models an active legal hold that would block `anonymise_user` from executing.
- **CNIL 13-month log purge is declarative, not enforced.** `user_activities` carries the retention COMMENT; no partitioning, TTL index, or scheduled DELETE exists to enforce the ceiling automatically.
