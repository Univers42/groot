# Track Binocle — Documentation

> **Status:** Verified · 2026-09-15
> **Evidence:** structure agreed in the restructure plan; every linked page exists
> **Sources:** [WIKI-AUDIT.md](../WIKI-AUDIT.md) · [restructure plan](../archive/wiki-2026-09/)

This is the curated wiki: short pages, one idea each, kept current. Anything longer or older
lives in [`archive/wiki-2026-09/`](../archive/wiki-2026-09/) and is linked from the relevant
page under **Deeper**.

**Three ways in.** Use whichever matches why you're here:

- **[ONBOARDING.md](ONBOARDING.md)** — new to the project? Seven pages, in order.
- **[DEFENSE.md](DEFENSE.md)** — preparing the 42 evaluation? Question → page.
- **This page** — you know what you're looking for.

---

## Catalogue

### [platform/](platform/) — grobase, the BaaS

Roughly 70% of the work. A self-hostable Backend-as-a-Service: one backend, any frontend,
zero per-project server code.

| Page | What it answers |
|---|---|
| [01-overview](platform/01-overview.md) | What grobase is, what it promises, what that costs |
| [02-planes](platform/02-planes.md) | The four planes and the seam that carries the load |
| [03-data-plane](platform/03-data-plane.md) | How queries execute; capability honesty |
| [04-control-plane](platform/04-control-plane.md) | Provisioning, tenancy, decide-above/apply-below |
| [05-realtime](platform/05-realtime.md) | Turning data changes into events |
| [06-contracts](platform/06-contracts.md) | How a JSON file becomes a database with keys |
| [07-isolation](platform/07-isolation.md) | Per-request owner scoping, and where it doesn't reach |
| [08-engines](platform/08-engines.md) | Reference: eight engines × capabilities |

### [product/](product/) — what users open

| Page | What it answers |
|---|---|
| [01-apps](product/01-apps.md) | The four products, and what only looks like an app |
| [02-osionos](product/02-osionos.md) | The block editor and its database block |
| [03-opposite-osiris](product/03-opposite-osiris.md) | Marketing site, auth, and the bridge |
| [04-repos](product/04-repos.md) | Repos, submodules, and why names disagree |

### [security/](security/)

| Page | What it answers |
|---|---|
| [01-model](security/01-model.md) | Trust boundaries, ABAC/RBAC |
| [02-proofs](security/02-proofs.md) | Which isolation claims are proven, and by what |
| [03-known-weaknesses](security/03-known-weaknesses.md) | What we know is weak, and why it's declared |
| [04-network](security/04-network.md) | SSRF guard, WAF, Kong, HTTPS |

### [operations/](operations/)

| Page | What it answers |
|---|---|
| [01-bring-up](operations/01-bring-up.md) | Getting the stack running |
| [02-flags](operations/02-flags.md) | Feature flags, and the trap that wastes an afternoon |
| [03-deployment](operations/03-deployment.md) | fly.io, Vercel, the binding boundary |
| [04-troubleshooting](operations/04-troubleshooting.md) | When it looks green but isn't |
| [05-secrets](operations/05-secrets.md) | vault42, 42ctl, bootstrapping your key |

### [quality/](quality/)

| Page | What it answers |
|---|---|
| [01-gates](quality/01-gates.md) | The verification system and its one rule |
| [02-key-gates](quality/02-key-gates.md) | The eight gates that matter, and what each proves |

### [project/](project/) — the 42 side

| Page | What it answers |
|---|---|
| [01-subject](project/01-subject.md) | What ft_transcendence asks for |
| [02-modules](project/02-modules.md) | Module ledger: points, flags, evidence |
| [03-team](project/03-team.md) | Roles and contributions |
| [04-glossary](project/04-glossary.md) | Project vocabulary |

---

## Conventions

Every page opens with a status block. **Verified** means we checked it and say how;
**Unverified** means we haven't, and says how to check and what breaks if it's wrong. The whole
ledger is in [STATUS.md](STATUS.md).

The backend's authoritative document is `apps/grobase/CLAUDE.md`, maintained by whoever touches
the code. This wiki distils and links; it does not duplicate. Where they disagree, CLAUDE.md
wins — after checking, since it has been wrong five times on verifiable details.

See also: [repository README](../README.md).
