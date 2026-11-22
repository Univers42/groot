# DRAFT. The gateway's verify-password route ships from a pushed develop commit through a git-archive build, with the old image kept as the rollback

- Status: proposed (draft, unnumbered). devil 2026-11-22: PROCEED-WITH-CONDITIONS VD1–VD9, option A.
- Date: 2026-11-22
- Deciders: devil (ruling); operator (deploy). Route design: DRAFT-verify-password-ruling.md (VP1–VP22).
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-verify-password-deploy.md`

## Context

- The live gateway ran exactly opposite-osiris a6b8f1c (26/26 files), seven commits behind develop edd3e81.
- The main groot checkout's opposite-osiris tree (f87e8ee) is an ancestor 53 commits back: a compose build from it would roll the live gateway back.
- The compose service needs `--profile local` and `GROBASE_LINK_DIR`; its config hash changed (ab628acd new vs 2a27055b live).
- The gateway has no SIGTERM handler; its in-memory mail queue is lost on any recreate.

## Decision

- VD1 build the image from a git-archive of a pushed commit ≥ 9768fd8, never from a working tree.
- VD2 no `--pull`; the Node major.minor must equal the live v22.23.x.
- VD3 hash every file under the image's `/app/scripts` and the grobase lib against the commit: 0 mismatches.
- VD4 tag the running image `:pre-verify-password` before retagging the new one `:local`.
- VD5 recreate only `auth-gateway` (`up -d --no-build --no-deps`); the config hash must match the reviewed one.
- VD6 deploy in a quiet window: no mail queued in the last 2 minutes.
- VD7 probes before and after (health, the unsigned route 400, the signed route 200, login, recover, newsletter, bridge sign-in), each probe session revoked.
- VD8 a 24 h watch of `%_turnstile_failed` audit rows and edge 403s on `/api/auth/*`; a real client refused means rollback.
- VD9 rollback = `:pre-verify-password` → `:local` and the VD5 command. Afterwards, merge the commit to develop and main and bump the groot pin.

## Consequences

- Deployed 2026-11-22 20:07Z (image sha256:2b100910df4c); every VD7 probe passed. The audit rows needed the CHECK widened (groot 95943e7f).
- The pin now names 9768fd8, the commit the image was built from.
- Option B, a deploy-only branch, is recorded in `.out-of-scope/deploy-only-gateway-branch.md`.
