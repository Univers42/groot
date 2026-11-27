# DRAFT. The prod bridge moves from main-077cc9a1 to main-d2db4373 with its switches off, under a value-level env check

- Status: proposed (draft, unnumbered). devil 2026-11-23: PROCEED-WITH-CONDITIONS BP1–BP10.
- Date: 2026-11-23
- Deciders: devil (ruling); operator (deploy). Units: osionos #322, #296. Riding along: #233, osio-bot, publish containers, hiddenFrom, BG3.
- Full ruling: `/mnt/storage/dlesieur/scratch/bridge-promo/RULING.md`

## Context

References are to osionos `d2db43733`.

- 31 commits touch `scripts`/`docker/services/bridge` since 077cc9a1. The Dockerfile is unchanged. The image copies only `scripts/bridge-*.mjs`, `scripts/ide-*.mjs` and `scripts/moderation-lists/`.
- These change behaviour with today's env:
  - #322: password step-up for `auth_method='password'` families (`scripts/bridge-account-sudo-password.mjs:46,84,92`).
  - #296: refresh re-grant and flagged-revoke refusal (`scripts/bridge-api.mjs:2078-2134`).
  - hiddenFrom: profile and follows filtering. A read fault answers 503.
- #233, osio-bot, publish containers and BG3 are inert: their switches are unset in the live container (`docker inspect`, names only).
- The bridge loads `.env.local` whole (`docker-compose.yml:83-85`). That file changed 76 s after the live bridge started, and the recreate adds `AUTH_LINK_SIGNING_KEY`, which the bridge never reads.
- The new code writes no schema. The only new state is Redis rate keys.

## Alternatives

- Cherry-pick #322 and #296 onto 077cc9a1 as a deploy-only branch. Rejected: it would be an untested hybrid. The same drift ships at the next promotion anyway.
- Wait for develop's next main fast-forward and promote once. Rejected: #296 (A296-13) and #322 (VP22) are waiting on this promotion. The extra units are inert under the current env.

## Decision

Promote through `deploy-bridge-main.sh` (build, then swap) from app-main at d2db43733.

## Consequences

PROCEED-WITH-CONDITIONS:
- BP1: value-digest env equality, with `+AUTH_LINK_SIGNING_KEY` the only difference allowed.
- BP2: switches off; required keys set.
- BP3: build through the tool only.
- BP4: #322 probe on a real password session. A false `passwordRequired` makes the probe invalid.
- BP5: hiddenFrom probe.
- BP6: 10-minute watch against a measured baseline.
- BP7: A296-14 now and again at +60–90 min.
- BP8: roll back on any failed bar.
- BP9: revoke the probe sessions.
- BP10: ledger entry.

Tabs loaded before the web went live at 2026-11-23 00:24Z fail closed (403 password_required) on sudo for password sessions until they reload.

## Outcome (2026-11-23)

Swapped at 20:36:16Z, main-077cc9a1 → main-d2db4373. BP1 0 changed / 0 removed after four link-derived
keys were pinned in the deploy tree (the rendered env had drifted to the link's ssh-mode values); BP4/BP5
all as expected; BP6 restarts 0 and 0 error-pattern hits (the bridge writes no per-request log line, so
the 5xx bar sees only crashes and logged errors); A296-14 first run unchanged; BP9 sessions revoked;
BP10 in the deploy ledger and `deploy/DEPLOY-NOTES.md`. BP7 second run 21:40:18Z: A296-14 unchanged (2 flagged accounts, each with a current admin grant), probe296 2/2 PASS, restarts 0. All BP items closed; rollback not used.
