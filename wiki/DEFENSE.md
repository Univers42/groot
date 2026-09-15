# Defense map — question → page

> **Status:** Verified · 2026-09-15
> **Evidence:** questions drawn from ft_transcendence subject v21.2, chapters III–VIII
> **Sources:** [project/01-subject](project/01-subject.md) — our own checklist. The 42 subject
> itself is not in this repository; the team holds it privately.

What an evaluator is likely to ask, and where the answer lives. Bring
[project/02-modules](project/02-modules.md) to the evaluation; bring this to the preparation.

---

## Before anything else — the rejection criteria

These are not points. They are pass/fail, and none of them is technical.

| Check | Where | Status |
|---|---|---|
| Privacy Policy and Terms of Service, reachable, real content | `apps/opposite-osiris` | **Unverified** |
| Commits from every team member, visible work split | `git shortlog -sn --all`, root and each submodule | **Unverified** |
| No JavaScript warnings or errors in the browser console | all six frontends, DevTools open | **Unverified** |
| Single-command containerised deployment | [operations/01-bring-up](operations/01-bring-up.md) | Verified |
| HTTPS for every connection from a browser or script | [security/04-network](security/04-network.md) | Verified |

Do these first. Nothing else matters if one of them fails.

---

## Likely questions

### "Explain your architecture."

The one you win. → [platform/02-planes](platform/02-planes.md), then
[platform/01-overview](platform/01-overview.md) for the why.

### "How do you guarantee tenant isolation?"

→ [platform/07-isolation](platform/07-isolation.md) and [security/02-proofs](security/02-proofs.md).

Say the long version, including the HTTP exception. The short version collapses the moment
anyone pulls the thread.

### "What's the weakest part of your system?"

→ [security/03-known-weaknesses](security/03-known-weaknesses.md).

Answer it yourself before they find it. `identity/identity.go` documents an authorisation
weakness in its own header comment; that file is in the repository and can be read.

### "Show me the database schema."

→ [platform/06-contracts](platform/06-contracts.md) and [platform/08-engines](platform/08-engines.md).

Do **not** answer "schemas are dynamic". True, and the worst possible answer. Show the SQL
migrations and the control-plane registries: real tables, real relations.

### "Which modules are you claiming, and where is each one?"

→ [project/02-modules](project/02-modules.md). Every claim has a flag to raise, a gate that
proves it, and a screen that demonstrates it. Non-functional module = zero points.

### "How do you know it works?"

→ [quality/01-gates](quality/01-gates.md) and [quality/02-key-gates](quality/02-key-gates.md).
160 scripts, and the rule that a gate passing vacuously is not a gate.

### "Is this actually multi-user / real-time?"

→ [platform/05-realtime](platform/05-realtime.md). Note that realtime is **not** in the default
edition — see [operations/01-bring-up](operations/01-bring-up.md) before demonstrating.

### "Why did you build your own backend instead of using one?"

→ [platform/01-overview](platform/01-overview.md). Include the cost, not just the upside.

---

## Demonstration notes

**There is a live public deployment.** Multi-user, HTTPS, public API, email OTP to a real
inbox and two non-merging databases proving per-user isolation can all be shown on the running
system rather than on a laptop. Have both paths ready — see
[operations/03-deployment](operations/03-deployment.md).

**The strongest single demo** is gate `m174`: osionos querying six engines through one
application key. → [quality/02-key-gates](quality/02-key-gates.md).

**Live modification.** Chapter VIII allows a small change on the spot. Rehearse the fast path
(`docker compose up -d --build <service>`) beforehand.

---

See also: [catalogue](README.md) · [status ledger](STATUS.md)
