# DRAFT. The live audit CHECK is widened by one bounded transaction, with every sudo_* event the deployed gateway emits

- Status: proposed (draft, unnumbered). devil 2026-11-22: BLOCK as submitted (4 values); PROCEED-WITH-CONDITIONS SA1–SA8 once all 6 are listed.
- Date: 2026-11-22
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-sudo-audit-constraint.md`

## Context

- The redeployed gateway (image sha256:2b100910df4c, opposite-osiris 9768fd8) logs `violates check constraint "auth_audit_events_event_type_check"`; `audit()` swallows it (`scripts/auth-gateway.mjs:270-275`), so the rows are lost.
- `scripts/auth/verify-password.mjs` emits six sudo_* events (:161, :188, :198, :211, :221, :230). Branch fix/sudo-audit-events (groot 3a87e06d) added four. `scripts/tests/auth-audit-events.bats` against the deployed source: 7/8, test 8 fails on `sudo_password_grant_timeout` and `sudo_password_lockout_triggered`.
- Live (read-only, PG 16.15): 79 listed values equal the file's pre-edit list; 4,327 rows, 3.8 MB; 0 triggers; 0 sudo_* rows; the table rides the all-tables publication `mini_baas_outbox_pub` to an active Debezium slot.

## Alternatives

- Re-run the whole 219-line migration: same end state, more statements on live than the change needs.
- Apply four values (as submitted): the lockout-triggered row, the brute-force signal, stays lost once the bridge calls the route.
- `ADD CONSTRAINT ... NOT VALID` then `VALIDATE`: avoids the scan, but the scan is 3.8 MB; not worth the second step.

## Consequences

- SA1 six values, bats 8/8 against scripts copied from the live container. SA2 delta vs live = exactly +6. SA3 one txn, lock_timeout 3s, retry unchanged on timeout.
- SA4 rollback only before the first sudo_* row; afterwards forward-only, and audit rows are never deleted to re-validate the old list.
- SA5 probe row checked without email/ip/user_id. SA6 no constraint warning after apply. SA7 Debezium slot still active and advancing. SA8 the committed file equals live; FF check before pushing develop and main.
