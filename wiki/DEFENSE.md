# Defense map — the evaluation grid, answered

> **Status:** Verified · 2026-09-15
> **Evidence:** follows the official peer-evaluation grid item by item, in its order
> **Sources:** the evaluation grid · [project/01-subject](project/01-subject.md)
> **Legend:** ✅ we can answer · ⚠️ needs checking before the day · ❌ known gap

Bring [project/02-modules](project/02-modules.md) to the evaluation; bring this to the preparation.

---

## Hard stops — these end the review

| Item | State | What to do |
|---|:--:|---|
| **All 4–5 members present.** Absent member → *the review stops here* | ⚠️ | Confirm attendance now. Nothing else matters if this fails. |
| **Credentials found anywhere outside `.env`** → *immediate failure* | ⚠️ | `git grep -nE "(password\|secret\|api[_-]?key\|token)\s*=\s*['\"][^'\"]{8,}"` across root and every submodule. Also check `deploy/fly/boot.sh` defaults and any committed `.env`. |
| **Privacy Policy / Terms of Service** missing or placeholder → *rejection* | ❌ | Two real pages on opposite-osiris, footer links. Cheapest risk in the whole evaluation. → [product/03-opposite-osiris](product/03-opposite-osiris.md) |
| **`git clone` into an empty folder** must produce the evaluated project | ⚠️ | Rehearse it. `--recursive`, then `make all`. If `apps/grobase/` comes up empty, ~70% of the work is outside what gets graded. → [product/04-repos](product/04-repos.md) |
| Malicious aliases / grading scripts | ✅ | They may ask to review any helper script. Ours are plain: `make` targets are thin wrappers over `scripts/verify/`. Offer to open them. |

---

## Preliminaries — team

| Item | State | Answer / where |
|---|:--:|---|
| Each member explains **their role**, **their contributions**, and **one feature they personally implemented** | ❌ | [project/03-team](project/03-team.md) is still a template. Fill it, then each person rehearses their own three answers. |
| **README** has all required sections | ❌ | The current README is an operations README, not a 42 README. Missing sections listed in [project/01-subject](project/01-subject.md). |
| **At least two different members** explain the concept, the stack and how you coordinated | ⚠️ | [ONBOARDING.md](ONBOARDING.md) is the ninety-minute path that makes this answerable. The concept in one line: *a workspace whose database block views any source, on a BaaS that hosts any frontend without per-project server code.* |
| Git history shows commits from everyone | ⚠️ | `git shortlog -sn --all`, root and each submodule. Not fixable in the final week. |

---

## General requirements

| Item | State | Answer / where |
|---|:--:|---|
| Frontend, backend, database — different members explain each | ✅ | [product/01-apps](product/01-apps.md) · [platform/02-planes](platform/02-planes.md) |
| **Single-command containerised deployment** | ✅ | `make all` from a clean clone, CI-proven. → [operations/01-bring-up](operations/01-bring-up.md) |
| Chrome console: **no errors or warnings** | ⚠️ | Never verified — all checks so far were `curl` from a headless VM. Open all six frontends with DevTools. Third-party warnings are tolerated *if explained*, so know what each one is. |
| Privacy Policy / ToS | ❌ | See hard stops. |

---

## Technical requirements

| Item | State | Answer / where |
|---|:--:|---|
| Responsive on **two screen sizes** | ⚠️ | Untested in anything we hold. Check desktop and mobile on each frontend. |
| **A CSS framework** — "plain CSS alone is not sufficient" | ⚠️ | Identify and be ready to show usage in code. If a frontend uses hand-written CSS only, that is a gap worth closing now. |
| `.env` gitignored, `.env.example` present, no secrets committed | ⚠️ | See hard stops — this one has a failure clause attached. |
| **Database schema** with clear relations | ✅ | Do **not** say "our schemas are dynamic". Show the SQL migrations and the control-plane registries, then `website.schema.sql`. → [platform/06-contracts](platform/06-contracts.md) |
| Auth: email + password, **hashed and salted**, team explains the approach | ✅ | argon2id in the data plane's `one` edition; API keys hashed with a pepper generated on first boot. → [security/01-model](security/01-model.md) |
| **Validation on frontend *and* backend** — they will try SQL injection and XSS | ⚠️ | Backend side is strong: the operation envelope is narrow by design and queries are parameterised per adapter. Verify the **frontend** half, and try the attacks yourself first. → [platform/03-data-plane](platform/03-data-plane.md) |
| HTTPS everywhere | ✅ | TLS proxy, local CA, green padlock; live deployment on real HTTPS. → [security/04-network](security/04-network.md) |

---

## Modules

The README must list them with the point calculation, and **each one is demonstrated
individually**. Non-functional = 0, not partial credit.

Full ledger with what to raise, what proves it and what to click:
**[project/02-modules](project/02-modules.md)**.

Two things the grid adds: **dependencies are checked** — gaming modules need a working game, we
have none, so that category and the AI-opponent module are out — and **custom modules** need the
four-part justification in the README (why, what challenge, what value, why that weight). Our
recommendation: the contract-driven factory as major, the SSRF guard as minor.

---

## Code quality and teamwork

| Item | State | Answer / where |
|---|:--:|---|
| Code organised and readable | ✅ | The plane layout and the no-`shared`-junk-drawer rule. → [platform/02-planes](platform/02-planes.md) |
| **Technical choices, challenges and trade-offs** | ✅ | The strongest question you get. Every decision in the wiki carries its cost — narrow expressiveness, duplicated ABAC logic, eight-way parity. Say the cost, not just the benefit. → [platform/01-overview](platform/01-overview.md) |
| Members explain **each other's** work; no single person did it all | ⚠️ | [ONBOARDING.md](ONBOARDING.md), and the git history again. |

---

## Functionality

| Item | State | Answer / where |
|---|:--:|---|
| Stable, main features work, basic error handling | ✅ | Errors map to real status codes, and the planner rejects rather than returning a partial result. → [platform/03-data-plane](platform/03-data-plane.md) |
| **Multiple users simultaneously** | ✅ | Two browsers, two accounts, live collaboration. Raise `EDITION=realtime\|prod\|full` first — realtime is **not** in the default edition. → [platform/05-realtime](platform/05-realtime.md) |
| Effort and learning, beyond the minimum | ✅ | Three planes, eight engines, a live deployment, a security product built on top. → [operations/05-secrets](operations/05-secrets.md) |

---

## Bonus

Only if the mandatory part is **entirely and perfectly** done. Maximum 5 points, same
demonstration and same README justification as any other module.

---

## What to rehearse

**The demo order.** Sign-up with a real email OTP → the workspace → the database block over six
engines (`m174`) → two browsers editing live → a `POST /v1/tenants/me/apps` creating a whole new
backend.

**The three answers that win points.** How isolation works *including the HTTP exception*
([platform/07-isolation](platform/07-isolation.md)); what your weakest part is, said before they
find it ([security/03-known-weaknesses](security/03-known-weaknesses.md)); and how you know it
works — a named gate per claim ([quality/02-key-gates](quality/02-key-gates.md)).

**The fast build path**, in case they ask for a live modification:
`docker compose up -d --build <service>`.

**Both environments ready** — live deployment and local stack, each covering the other's failure
mode. → [operations/03-deployment](operations/03-deployment.md)

---

See also: [README.md](README.md) · [STATUS.md](STATUS.md) · [project/02-modules](project/02-modules.md)