# Team, roles and contributions

> **Status:** Unverified — **this page is a template. The facts are not in any document we hold.**
> **To fill:** run `git shortlog -sn --all` at the root and in each submodule, then complete the
> tables below with the team. Everything in `<angle brackets>` is a gap.
> **Sources:** to be supplied by the team · required by the subject, chapters II and VI

The subject requires named roles, a documented work split, and each member able to explain their
own contribution. This page is where that lives, and it is also the source for the README
sections the evaluation grades. → [01-subject](01-subject.md)

---

## Members and roles

The subject asks for four roles. With four people some are combined; with five they can be
distinct.

| Member | 42 login | Role(s) | Responsibilities |
|---|---|---|---|
| `Dylan Lesieur` | `dlesieur` | Product Owner / All | Product vision, backlog, priorities, validates completed work |
| `Sergio Jiménez` | `serjimen` | Project Manager / Developer | Frontend, secrets, deployment |
| `Daniel Fernández` | `danfern3` | PO / Tech Lead | Architecture, stack decisions, code quality, reviews |
| `Vadim Jan` | `vjan-nie` | Project Manager / Developer | Planning, tracking, communication, unblocking |
| `<name>` | `<login>` | Developer | Features and modules |

---

## How the work was organised

- **Task tracking:** `<tool>`
- **Communication:** `<channel>`
- **Meeting rhythm:** `<cadence>`
- **Code review:** `<practice>`

---

## Contributions by area

Fill against the git history rather than from memory — the evaluation checks the history.

| Area | Who | Notes |
|---|---|---|
| grobase — control plane (Go) | `<who>` | |
| grobase — data plane (Rust) | `<who>` | |
| grobase — realtime (Rust) | `<who>` | |
| osionos | `<who>` | |
| opposite-osiris | `<who>` | |
| mail / calendar | `<who>` | |
| vault42 / 42ctl | `<who>` | |
| Infrastructure, CI, deployment | `<who>` | |
| Documentation | `<who>` | |

```sh
git shortlog -sn --all                    # repository root
git submodule foreach 'git shortlog -sn --all'
```

---

## How AI was used

The subject requires this explicitly, in the README's Resources section: which tasks, which
parts of the project. It devotes its entire first chapter to the topic, so omitting it reads
worse than declaring it.

This project was built with heavy AI assistance. Describe it precisely rather than vaguely —
`<which tools, for which tasks, on which parts>` — and note where output was reviewed, tested or
rewritten. The subject's own framing is that AI-generated work you cannot explain is the classic
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
- `<add yours>`

---

See also: [01-subject](01-subject.md) · [ONBOARDING.md](../ONBOARDING.md)
