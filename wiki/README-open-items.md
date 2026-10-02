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

## Team Information and Project Management

| README section | Item | Context |
|---|---|---|
| Team Information | Resolve the role overlap | The table copies `wiki/project/03-team.md`: two Product Owners (`dlesieur`, `danfern3`) and two Project Managers (`serjimen`, `vjan-nie`). The subject expects PO, PM and Tech Lead each clearly assigned; every member must defend what is next to their name. |
| Team Information | `shashemi`: full name, real role and scope | The row uses the template's fifth-member line ("Developer — Features and modules"). `dlesieur`'s development scope is also unstated. |
| Project Management | Work organisation | How tasks were split (by plane? by product?), sprint length, meeting cadence, how decisions were recorded. Not in the repository. |
| Project Management | Task-tracking tool | GitHub Issues / Projects, Trello, Notion…? The repository shows only PRs and the milestone files. |
| Project Management | Review rules | Required reviewers / branch protection are GitHub settings, not in the repository. |
| Project Management | Communication channels | Discord, Slack, campus…? |

## Technical Stack and Database Schema

| README section | Item | Context |
|---|---|---|
| Technical Stack | Is plain CSS in mail and calendar acceptable? | The subject requires "a CSS framework or styling solution". osionos uses Tailwind, the site Sass; mail and calendar (`apps/mail`, `apps/calendar` at the pinned commits) ship only `src/styles.css`. `wiki/STATUS.md` open check #7. |
| Database Schema | grobase registry tables with key columns | Read them from grobase's own migrations and add them to the schema section (tenants, mounts, roles, policies, API keys). |

## Features, Modules, Individual Contributions

| README section | Item | Context |
|---|---|---|
| Features List | **Legal pages still carry placeholders** — rejection criterion | opposite-osiris `src/data/legal.ts:17-18` (pinned `85815cd7`): data-controller name and address end in "(placeholder)". Replace with real content. |
| Features List | "Who" for every feature | Removed from the table because no file records it. Fill from the history, not from memory. The subject requires it. |
| Features List | Click through every feature in Chrome with the console open | None of the rows is marked verified. `make e2e` covers only the Whiteboard paths and Mail/Calendar opening. |
| Modules | "Who" for every module | Same as features. |
| Modules | Reach 14 demonstrable points | Only rows 1–4 and 13–14 (10 pts) work in the default stack. Raise the B flags, build the C screens, delete the rows the team will not defend. |
| Modules | Candidate: HashiCorp Vault (Cybersecurity, major) | Does grobase's `VaultProvider` talk to HashiCorp Vault (migration `060`)? Our own secrets use vault42. `wiki/STATUS.md` open check #10. |
| Modules | Candidate: LLM interface / analytics dashboard | Read grobase `src/apps/ai/` and `src/apps/analytics/`. `wiki/STATUS.md` open check #11. |
| Modules | Candidate: Multiple languages (Accessibility, minor) | Not available today: osionos' language switch is a stub (`src/features/settings/SettingsCenter.tsx`, `i18n_change_stub`), and no locale resources exist. Needs ≥ 3 complete languages. |
| Modules | Check every module name and point value against the current subject version | `wiki/project/01-subject.md` is our paraphrase of subject v21.2. |
| Individual Contributions | One subsection per member | Contributed / features and modules / challenges and how they were overcome — backed by the root **and** submodule history. Every member will be asked to explain their part. |
| Individual Contributions | Map git authors to logins | Author names in the pinned submodules include `LESdylan`, `danielfdez17`, `settes`, `DJSurgeon`, `Seyed Mostafa Hashemian` / `SMOSTAFAH1`, `bunny`, `vjan-nie` / `Vado` / `Vadim J N` (`git -C <submodule> shortlog -sn <pinned sha>`, 2026-10-01). Only the team can say who is who. |
| Individual Contributions | More team-level challenges | The list has three; add the others the team faced. |

## Resources, limitations, licence

| README section | Item | Context |
|---|---|---|
| Resources | Articles and tutorials the team actually used | The list holds reference documentation only. |
| Known limitations | Responsive layout, clean console on every frontend, concurrent users | All graded, none verified (`wiki/STATUS.md` open checks #6, #8). |
| License | Add a `LICENSE` or state the project is not licensed for reuse | The README now states only that no root `LICENSE` exists. |
