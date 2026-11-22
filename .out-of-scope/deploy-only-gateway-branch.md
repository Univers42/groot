# A deploy-only gateway branch for verify-password is out of scope

- Decided: 2026-11-22 · by devil (RULING-verify-password-deploy, option B rejected)
- Holds while: the gateway image is built from a pushed opposite-osiris commit on develop

## The concept

Build the live gateway from a branch that carries only the verify-password commits on top of the running a6b8f1c, leaving the seven develop commits since then out of the deploy.

## Why not

- A branch that is neither develop nor main is a third line nobody merges back; the next deploy from develop would ship the seven commits untested anyway.
- The seven commits were reviewed and green on develop; holding them back buys no safety, only a later, larger diff.
- Option A built from 9768fd8 (a develop commit, then fast-forwarded to main) through a git-archive context, so the image matches a pushed tree file for file (VD3 hash check: 0 mismatches).
