# DRAFT. An admin API clears the identity admin flag, refuses env-listed targets, and signs the target out

- Status: proposed (draft, unnumbered). devil 2026-11-23: PROCEED-WITH-CONDITIONS D343-1 to D343-20.
- Date: 2026-11-23
- Deciders: devil (ruling); osionos builder. Issue: osionos #343 (follow-up of #296, A296-9).
- Full ruling: `/mnt/storage/dlesieur/scratch/pv343/RULING.md`

## Context

References are to osionos develop b5ef8cda3.

- No code clears `osionos_bridge_identities.is_admin`. The flag is sticky across env removal (`bridge-api.mjs:2078-2096`).
- Sign-in re-sets the flag for a verified address in `OSIONOS_ADMIN_EMAILS` on every sign-in, and answers admin even when that write fails (`bridge-api.mjs:2063-2065`, `:2085-2092`).
- bridge-perms and the Claude agent route trust the token claim without a re-read (`bridge-perms.mjs:257,266,276,284`, `bridge-api.mjs:2857`). The claim lives up to 3600 s (`bridge-api.mjs:148`).
- Sign-in and refresh write two flag-implied rights, the `user_roles` grant and the admin-workspace membership, with no re-check (`bridge-api.mjs:2100-2140`, `:2186-2189`).
  - A write still in flight can land after a demotion. A surviving grant is durable admin through `platform_role`.
- Refresh and sign-in take `now` before the claim reads (`bridge-sessions.mjs:520`, `bridge-api.mjs:2243`). A per-user cut-off written after the clear therefore refuses every token minted from a pre-clear read (`bridge-session-cutoff.mjs:144-155`).

## Alternatives

- **The plan as submitted (flag + grant):** it fails its own done-when. An env-listed target is re-promoted at its next sign-in. The live claim keeps bridge-perms for up to 1 h. The membership is left behind. A racing refresh can bring the grant back.
- **A demoted marker that env promotion honours:** rejected (`.out-of-scope/admin-demote-marker-over-env.md`). It changes what sign-in promotes, which is out of scope, and it puts a third authority above ADR 0005's root of trust.
- **One RPC making both writes atomic:** live DDL with its own gate. Not needed: flag-first ordering leaves a stable half-state that a retry repairs.
- **Every claim-only check re-reads the flag:** it would drop `user_roles`-only admins from bridge-perms, a behaviour change. The cut-off reaches the same done-when through an existing primitive.

## Decision

- Add `POST /api/account/admin/users/:userId/demote`. It is gated by the users dispatcher, `requireAdmin` and `requireSudo`, and it writes the audit row first.
- It refuses: self-demotion, an env-listed target (primary or verified secondary), and a concurrent demotion (global kv lock, with the caller's flag re-read inside the lock).
- Write order: flag (both `user_id` and `subject` keys), then grant, then admin-workspace membership, then the per-user cut-off. A read-back follows, and a partial run answers 503 `demote_incomplete` so it can be retried.
- `ensureAdminRoleGrant` and `ensureAdminWorkspaceMembership` re-read the flag after they write and undo the write when it reads false.

## Consequences

- PROCEED-WITH-CONDITIONS D343-1 to D343-20 (see the full ruling).
- No migration. Before promotion, two read-only checks are required:
  - is there a CHECK on `osionos_bridge_audit_events.event_type`? If so, reuse `admin_role_change`;
  - are cut-offs enforced on the deployed bridge?
- The compensation (D343-10) ships in the same promotion as any refresh re-grant (#296).
- An address added to `OSIONOS_ADMIN_EMAILS` after a demotion re-promotes. That is by design (ADR 0005).
- Reopen if `user_roles` becomes the single admin authority, or if env promotion stops being the root of trust.
