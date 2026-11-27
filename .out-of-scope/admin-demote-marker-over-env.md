# A "demoted" marker that overrides OSIONOS_ADMIN_EMAILS promotion is out of scope

- Decided: 2026-11-23 · by devil (ruling on osionos#343)
- Holds while: sign-in promotes every verified address in `OSIONOS_ADMIN_EMAILS` (ADR 0005, the env list is the root of trust)

## The concept

When an admin demotes an account through the demote API, record the demotion (a column on
`osionos_bridge_identities` or an audit lookup). Sign-in would then skip the env-list promotion for
that account, so the demotion sticks even though the account's address is still in
`OSIONOS_ADMIN_EMAILS`.

## Why not

- Sign-in sets the flag for a verified env-listed address on every sign-in, and answers admin even when that write fails (osionos `bridge-api.mjs:2063-2065`, `:2085-2092`). A marker means changing what sign-in promotes, which #343 puts out of scope.
- It makes an API call outrank the deploy-time env list. Two authorities would then disagree about the same address, and the env list could no longer be relied on to recover a platform that has lost its admins.
- The demote API refuses an env-listed target instead (409 `admin_email_listed`, D343-5). Removing the address from env and then demoting gives the same result, with one authority.
- What would change the answer: env promotion stops being the root of trust, for example if `resolveAdminFlag` stops PATCHing the flag from `config.adminEmails`.

## Prior requests

- 2026-11-23 (#343 ruling): raised as the minimum way to make a demotion survive the env-list sign-in.
- Related: `.out-of-scope/admin-role-revoke-marker.md` (2026-11-22), a marker on the `user_roles` revoke.

## Reopen when

`resolveAdminFlag` (osionos `scripts/bridge-api.mjs`) no longer writes `is_admin` from
`OSIONOS_ADMIN_EMAILS`.
