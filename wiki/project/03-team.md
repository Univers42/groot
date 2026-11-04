# Team, roles and contributions

> **Status:** Partly verified. Names, logins and the work split come from the git history;
> roles come from the team's notes. Lines marked "TO CONFIRM by the team" are facts no document
> or commit holds.
> **Sources:** `scripts/contributors.sh` (2026-11-04) · [`.mailmap`](../../.mailmap) · the
> original roster in [`archive/wiki-2026-09/CONTRIBUTORS.md`](../../archive/wiki-2026-09/CONTRIBUTORS.md)
> · required by the subject, chapters II and VI

The subject requires named roles, a documented work split, and each member able to explain their
own contribution. The README's "Team Information", "Project Management" and "Individual
Contributions" sections hold the facts; this page records where they come from. → [01-subject](01-subject.md)

---

## Members and roles

| Member | 42 login | Role(s) | Responsibilities |
|---|---|---|---|
| Dylan Lesieur | `dlesieur` | Product Owner · Developer | Product vision, backlog, priorities, validates completed work |
| Daniel Fernández | `danfern3` | Tech Lead · Developer | Architecture, stack decisions, code quality, reviews |
| Sergio Jiménez de la Cruz | `serjimen` | Developer | Frontend, secrets, deployment |
| Vadim Jan Nieto | `vjan-nie` | Project Manager · Developer | Planning, tracking, communication, unblocking |
| Seyed Mostafa Hashemian | `shashemi` | Developer | TO CONFIRM by the team |

One owner per role, confirmed by the team on 2026-11-04: Product Owner `dlesieur`, Project
Manager `vjan-nie`, Tech Lead `danfern3`; `serjimen` is a Developer.

> TO CONFIRM by the team: `shashemi`'s responsibilities.

---

## How the work was organised

- **Task tracking:** GitHub Issues on `Univers42/groot` and the submodule repositories.
- **Communication:** Discord (confirmed by the team, 2026-11-04).
- **Meeting rhythm:** a weekly meeting (confirmed by the team, 2026-11-04).
- **Code review:** pull requests into `develop`, then `develop` into `main`; merged pull requests
  per login are in the README's [Who committed where](../../README.md#who-committed-where).

> TO CONFIRM by the team: who attended the weekly meeting, where its decisions were written,
> and who reviews whose pull requests.

---

## Contributions by area

From the commits touching each area (`scripts/contributors.sh --paths REPO PATH...`, all
branches, merges excluded, 2026-11-04, before that day's history rewrite); "whole repository"
rows are `scripts/contributors.sh`, merges included. A count is not effort. Until a clone drops
its pre-rewrite refs, `--all` counts the rewritten commits twice: the README's
[Who committed where](../../README.md#who-committed-where) counts from the pinned commits instead.

| Area | Who (commits) |
|---|---|
| grobase — control plane (Go), `src/control-plane` with `orchestrators/compose` | dlesieur 205, vjan-nie 2, shashemi 1 |
| grobase — data plane (Rust), `src/data-plane-router` | dlesieur 99, vjan-nie 3 |
| grobase — realtime (Rust), `infra/docker/services/realtime` | dlesieur 43, vjan-nie 5, shashemi 1 |
| osionos, `src` | dlesieur 1239, danfern3 78, vjan-nie 77, serjimen 76, rstancu 38, shashemi 8 |
| opposite-osiris (whole repository) | serjimen 177, dlesieur 150, shashemi 60, vjan-nie 23, danfern3 8 |
| mail / calendar (whole repositories) | dlesieur 37 / 22 |
| drawnosaurus (whole repository, at groot's pin `41900d75`) | dlesieur 676, danfern3 25, shashemi 9, vjan-nie 6; 111 by `bunny`, `Space Bunny` and `builder`, not mapped to a member |
| QA (whole repository) | vjan-nie 39, rstancu 2, danfern3 1, dlesieur 1 |
| monkey-bot (whole repository) | danfern3 133, rstancu 7, dlesieur 2 |
| Infrastructure, CI (root `infrastructure`, `.github/workflows`) | dlesieur 263 / 76, vjan-nie 20 / 14, shashemi 9 / 4, danfern3 2 / 0 |
| vault42 / 42ctl | not counted: the repository is outside this tree |
| Documentation | not counted: docs are spread over every repository |

```sh
scripts/contributors.sh                                   # every repository, one line per member
scripts/contributors.sh --paths apps/grobase src/data-plane-router
```

---

## How AI was used

The subject requires this explicitly, in the README's Resources section: which tasks, which
parts of the project. It devotes its entire first chapter to the topic, so omitting it reads
worse than declaring it.

This project was built with heavy AI assistance. Describe it precisely rather than vaguely —
see the README's "How AI was used" for the project-level answer, and note where output was
reviewed, tested or rewritten.

> TO CONFIRM by the team: which tools each member used, for which tasks, on which parts. The subject's own framing is that AI-generated work you cannot explain is the classic
way to fail an evaluation, so the useful disclosure is the one paired with evidence of
understanding.

---

## Two risks to face early

**Visible work split.** The subject requires commits from every member and a proper distribution
across the team. If the history does not show that, it is not something that can be fixed in the
final week. Look at `git shortlog` now rather than the day before.

**Everyone must be able to explain the project.** Not just their own part — the project. This is
not delegable: each person has to build their own mental model of their area. The
[onboarding path](../ONBOARDING.md) is designed for exactly that and takes about ninety minutes.

Worth knowing early how many of you can hold an hour of questions.

---

## Challenges faced

The README asks for this too, and honest entries read better than heroic ones. Candidates from
the project's actual history:

- Migrating the data plane from TypeScript to Rust without downtime, using per-request switching
  and shadow mode → [platform/02-planes](../platform/02-planes.md)
- Keeping eight engine adapters at parity → [platform/03-data-plane](../platform/03-data-plane.md)
- Auditing our own authorisation path and shipping a reversible mitigation
  → [security/03-known-weaknesses](../security/03-known-weaknesses.md)

> TO CONFIRM by the team: the challenges each member met.

---

See also: [01-subject](01-subject.md) · [ONBOARDING.md](../ONBOARDING.md)
