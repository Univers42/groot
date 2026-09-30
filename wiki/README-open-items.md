# README — open items for the team

> **Status:** Open · 2026-10-01
> **Sources:** the 🚧 TODO / 🔍 CHECK markers removed from the root `README.md` (branch
> `docs/readme-defense-ready`)

The README now carries only what the repository proves. Every marker the repository could not
answer moved here with its context. Close an item by writing the answer into the README section
named in the first column, then delete the row.

---

## Security — before the evaluation

| README section | Item | Context |
|---|---|---|
| Instructions → Team setup | **Committed credentials.** The vault passphrase and the demo account password are still in tracked files. Remove them, then **rotate** both (they stay in git history). | Found 2026-10-01 with `git grep -n -I -E 'Osionos123\|PASSPHRASE='`: `FRESH-START-LOG.md:18`, `FRESH-START-AGENT-PROMPT.md:31,37`, `DATA-MIGRATION.md:164`, `infrastructure/makes/repo.mk:183`, `scripts/showcase.sh:35`, `scripts/check-health-apps.sh:73`. Committed credentials are an immediate-failure criterion (`wiki/STATUS.md`, open check #2). |

## Instructions

| README section | Item | Context |
|---|---|---|
| Prerequisites | Switch submodule URLs to HTTPS, or keep SSH? | `.gitmodules` uses `git@github.com:` for every submodule except `apps/drawnosaurus`. The README now states an SSH key is required; an evaluator without one fails at the clone. |
| Instructions | What does a fresh local account see? | The old README said demo data is tied to the team's keys and invisible to a new account. `live-data-ensure` (`infrastructure/makes/baas.mk:66`) now re-stamps seeded demo rows onto the new owner, so that may no longer hold. Verify on a clean clone, then describe it (the "Local mode starts empty" limitation was removed as unproven). |
| Access | LiveKit plain `ws://` on `0.0.0.0` inside a NAT VM | Kong `:8000` is literal loopback (grobase `orchestrators/compose/base/gateway.yml:51`). LiveKit `:7880` uses `TRACK_BINOCLE_BIND_ADDR`, which is `0.0.0.0` in a QEMU/VirtualBox NAT VM (`infrastructure/scripts/detect-bind-addr.sh`). Decide whether that counts as an external plaintext connection under the subject's HTTPS rule. |
| Prerequisites | Disk figure from a clean build | The README's 30 GB comes from `docker system df` on the dev VM with the stack running (2026-10-01), not from a clean build. Re-measure after a clean clone if the number matters. |
