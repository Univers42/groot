# A revoke marker that stops sign-in or refresh re-granting admin is out of scope

- Decided: 2026-11-22 · by devil (ruling on osionos#296)
- Holds while: `requireAdmin` and the session claim decide admin from `osionos_bridge_identities.is_admin`, not from `user_roles`

## The concept

When an admin revokes the admin role (`user_roles` row) of an account whose `is_admin` flag is set,
record that revoke (a marker column or an audit row) and have the bridge skip re-writing the grant
at refresh, so the revoke sticks against an over-set flag.

## Why not

- A console revoke never demoted a flagged account. Only the users, audit and insights routes read the row. `requireAdmin` reads the flag, and the claim is set from the flag. (osionos `bridge-admin-check.mjs:47-55`, `bridge-perms.mjs:257-284`, `bridge-roles.mjs:71-73`)
- Sign-in already re-writes the grant on every sign-in (`bridge-api.mjs:2135-2138`). A marker would need honouring there too, and it would make the row the authority for three routes while the flag stays the authority for the rest.
- The over-set flag has to be corrected at the flag, and today no code clears it. The flag fix is the separate issue required by A296-9.
- What would change the answer: the flag stops being the admin authority, meaning `user_roles` becomes the only source that `requireAdmin` and the claim read. You would see it in `bridge-admin-check.mjs` and `claimPlatformRole`.

## Prior requests

- 2026-11-22 (#296 investigation): proposed as the way to make a revoke survive the refresh re-grant.

## Reopen when

`requireAdmin` and the session claim read `user_roles` instead of `is_admin`.
