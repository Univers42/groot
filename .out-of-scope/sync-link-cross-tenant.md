# Cross-tenant sync links are out of scope

- Decided: 2026-11-24 · by devil (draft ADR `docs/adr/DRAFT-grobase-sync-link-ruling.md`, R6)
- Holds while: the data plane's tenant-match check on `/v1/query` is off by default and no consent-scope ruling exists

## The concept

A grobase sync link whose source mount belongs to one tenant and whose target mount belongs to another. Consent comes from `appchannels`, so a CRM tenant can feed a partner's billing database. The MVP schema would reserve a `consent_id` column for it.

## Why not

- `/v1/query` trusts the tenant and the mount named in the request body. It refuses a tenant mismatch only when caller policy is on enforce, and that mode defaults to off (`srv/routes/caller_policy.rs:51-52`, `srv/routes/inbound_auth.rs:58`).
- Nobody has ruled on what a consent covers, how it can widen, or how fast a revocation stops writes. A link that keeps writing after revocation writes into another company's database.
- A `consent_id` column reserved now is YAGNI: a schema shape picked before the consent model exists.
- What would have to change: caller policy runs on enforce on main with the sync-link caller class (SL12), and a ruling fixes consent scope and a measured revocation latency.

## Prior requests

- 2026-11-24 (interop design D7, R6): cross-tenant links over `appchannels` consent, planned as a later phase.

## Reopen when

Caller policy enforce is the default on main, and a consent model with a measured revocation SLA is designed. Re-decide from scratch at that point.
