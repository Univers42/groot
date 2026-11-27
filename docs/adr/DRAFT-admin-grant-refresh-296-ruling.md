# DRAFT. A refresh re-writes the admin grant the identity flag implies, and the console refuses to revoke admin from a flagged account

- Status: proposed (draft, unnumbered). devil 2026-11-22: PROCEED-WITH-CONDITIONS A296-1 to A296-14.
- Date: 2026-11-22
- Deciders: devil (ruling); osionos builder. Issue: osionos #296.
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-296.md`

## Context

References are to osionos `origin/main` 1712b9649.

- The users, audit and insights routes gate on `public.user_roles`:
  - users: `bridge-account-users.mjs:208`;
  - audit: `bridge-account-audit.mjs:124`;
  - insights: `bridge-account-insights.mjs:123`.
- The rest of admin follows `osionos_bridge_identities.is_admin` or the claim derived from it:
  - `requireAdmin` reads the flag (`bridge-admin-check.mjs:47-55`);
  - `bridge-perms.mjs:257-284` reads the claim;
  - the claim is set from the flag (`bridge-roles.mjs:71-73`).
- Sign-in writes the grant for flagged accounts (`bridge-api.mjs:2135-2138`). Refresh does not (`:2173-2178`). As a result, a failed write or a revoke leaves a flagged admin refused by the console until the next sign-in, up to 7 days away.
- Refresh never sets the flag: `emailVerified: false` at `bridge-api.mjs:2174`.
- No code clears `is_admin`. The flag is over-set on two documented paths: auto-confirm signups (`bridge-api.mjs:2073-2075`) and an address made primary (`bridge-account-email-primary.mjs:22`).
- A console revoke of a flagged account does not demote it, and the next sign-in undoes it.

## Alternatives

- **Trust the token claim or the flag at the console:** rejected in REPORT-296. A revoked admin would keep control until the token expires, and the over-set flag would gain all three routes.
- **Re-grant on refresh but skip it after a revoke, using a marker or an audit row:** rejected (`.out-of-scope/admin-role-revoke-marker.md`). It would need the same check at sign-in, and it adds a third authority to a split that is already the bug.
- **Change nothing:** the #296 gap lasts up to 7 days after any failed write.

## Decision

- `readRefreshClaims` calls `ensureAdminRoleGrant` when the flag read is true. The call is best-effort and runs alongside the member-workspace read.
- `changeRole` answers `409 admin_flag_set` to a revoke of admin from any account with a flagged identity row. The message names clearing the flag as the real demotion.

## Consequences

- PROCEED-WITH-CONDITIONS A296-1 to A296-14 (see the full ruling).
- The change ships only with the next bridge promotion, after the gateway `verify-password` route is live (A296-13).
- A flagged account cannot be demoted from the console until a demote-the-flag path exists. That is tracked as an issue (A296-9).
- Reopen if `user_roles` becomes the single admin authority, meaning `requireAdmin` and the claim stop reading the flag.
