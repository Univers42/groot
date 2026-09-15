# What the subject requires — our checklist

> **Status:** Unverified — permanently, by nature. The source is not in this repository.
> **Subject version:** 21.2 · checked against it on 2026-09-15
> **To check:** re-read against the team's private copy whenever 42 publishes a new version, and
> update the date above
> **Sources:** the team's private copy of the ft_transcendence subject

**The subject is not in this repository and must not be.** `groot` is public and the subject is
42's material. The team holds it privately. This page is **our own list of what we have to
satisfy**, in our words — not a transcription. Any broken link elsewhere pointing at a subject
file can be deleted rather than fixed.

---

## Pass or fail — these are not points

Miss one and the project is rejected regardless of everything else.

- [ ] A web application with frontend, backend and database
- [ ] Privacy Policy and Terms of Service, reachable from the app, real content, not placeholders
- [ ] Deployment through containers, running with a single command
- [ ] Works in the current stable Chrome
- [ ] No JavaScript warnings or errors in the browser console
- [ ] Git shows commits from every member and a visible work split
- [ ] Multiple users at once, without conflicts, races or data corruption

Three of these are unchecked and none is technical. → [DEFENSE.md](../DEFENSE.md)

---

## Technical baseline

- [ ] Responsive, accessible frontend
- [ ] A CSS framework or styling solution
- [ ] Credentials in a local `.env` that git ignores, with a committed `.env.example`
- [ ] A clear database schema with defined relations
- [ ] Sign-up and sign-in with email and password, hashed and salted
- [ ] Input validated on **both** client and server
- [ ] HTTPS for every connection from outside; plaintext allowed only inside the backend

Note on the schema requirement: "our schemas are dynamic" is true and the worst possible answer.
Show the SQL migrations and the control-plane registries.
→ [platform/06-contracts](../platform/06-contracts.md)

---

## Points

**14 required.** A major module is worth 2, a minor 1. Aiming higher is advised, because modules
that cannot be demonstrated score zero — not partial credit.

Categories available: web · accessibility and i18n · user management · AI · cybersecurity ·
gaming and UX · devops · data and analytics · blockchain · free choice.

Free choice allows **one major and one minor**, each needing a written justification in the
README: why this module, what technical challenge it addresses, what value it adds, and why it
deserves its weight. That caps free choice at 3 points — the rest must come from the catalogue.

Our ledger lives in [02-modules](02-modules.md).

Dependencies worth knowing: all gaming modules require a working game first, and we have none,
which removes that whole category and the AI-opponent module with it. Advanced chat requires
basic chat.

---

## The README is graded

The subject specifies the README in detail, and ours does not currently comply. Required:

- [ ] First line, italic, stating the project was created as part of the 42 curriculum, with logins
- [ ] Description, Instructions, Resources
- [ ] **Resources must describe how AI was used** — for which tasks, on which parts
- [ ] Team information: each member's role and responsibilities
- [ ] Project management: how work was split, which tools, which channels
- [ ] Technical stack with justification for the major choices
- [ ] Database schema: structure, tables, relationships, key fields
- [ ] Feature list, with who built each
- [ ] Modules: which, how many points, justification, who implemented each
- [ ] Individual contributions in detail, including challenges faced
- [ ] Written in English

The AI disclosure is worth taking seriously rather than minimising: this project was built with
heavy AI use, the subject devotes its first chapter to the subject, and declaring it precisely
reads better than omitting it. → [03-team](03-team.md)

---

## On the day

Every member must be able to explain the project and their own contribution. The evaluators may
request a **small live modification** — a few minutes' work. Rehearse the fast build path
beforehand. → [operations/04-troubleshooting](../operations/04-troubleshooting.md)

---

See also: [02-modules](02-modules.md) · [DEFENSE.md](../DEFENSE.md)
