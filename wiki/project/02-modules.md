# Module ledger

> **Status:** Partial · 2026-09-15
> **Evidence:** flag states read from `deploy/fly/boot.sh`; every gate named here exists in the
> gate index
> **To check:** four items in the "open" table below are worth up to 6 points between them and
> none has been checked. Do those before building any screen.
> **Sources:** `deploy/fly/boot.sh` · `apps/grobase/CLAUDE.md` §flag-gating · [01-subject](01-subject.md)

Only catalogue modules count. **A module that cannot be demonstrated scores zero**, so each row
needs three things: what to raise, what proves it, and what an evaluator can click.

Confidence: **A** works as-is · **B** needs a flag and migration · **C** the engine exists but
the screen does not.

---

## Claimable

| Module | Pts | Raise | Proof | Conf |
|---|--:|---|---|:--:|
| Public API — key, rate limit, docs, 5 endpoints (Web, major) | 2 | nothing | Kong + `infra/config/openapi/` | **A** |
| Backend as microservices (DevOps, major) | 2 | nothing | 15 planes, `make planes` | **A** |
| Real-time via WebSockets (Web, major) | 2 | `EDITION=realtime\|prod\|full` | `m175` | **A** |
| Real-time collaboration (Web, minor) | 1 | same plane | `m175`, osionos | **A** |
| Advanced permissions (User mgmt, major) | 2 | `PERMISSION_CONDITIONS_ENABLED` + `API_KEY_ABAC_ENABLED`, migration `063` | `m135`–`m139` | **C** |
| Organisation system (User mgmt, major) | 2 | **already on in production** | `m103`, `m168`, `m170` | **C** |
| Prometheus + Grafana (DevOps, major) | 2 | observability plane; `TENANT_OBS_ENABLED` **and** `DATA_PLANE_TENANT_OBS` | `m85` | **C** |
| Health/status + backups + DR (DevOps, minor) | 1 | `TENANT_BACKUP_ENABLED`, migration `042` | `m87` | **C** |
| GDPR (Data, minor) | 1 | `HARD_ERASE_ENABLED` + `TENANT_EXPORT_ENABLED` | `m105`, `m109` | **B** |
| 2FA (User mgmt, minor) | 1 | TOTP in the `one` edition, or `PASSKEYS_ENABLED` | `m107` | **B** |
| OAuth 2.0 (User mgmt, minor) | 1 | `SSO_ENABLED`, migration `053` | `m110`, `m163` | **B** |
| File upload (Web, minor) | 1 | storage plane, `STORAGE_BUCKET_SCOPE_ENABLED` | `m159` | **C** |

Nominal total without free choice: **18**. Eight of those points are **A**.

**The key distinction:** organisation-system's backend is already running in production, so it
needs only a screen. The **B** rows need a flag, a migration and a gate run — but no new code.
Only the **C** rows need interface work, which is the expensive part.
→ [operations/02-flags](../operations/02-flags.md)

---

## Free choice

**Major (2 pts) — the contract-driven factory.** Recommended, because it demonstrates in thirty
seconds: `POST /v1/tenants/me/apps` creates a whole new tenant with its own `CREATE DATABASE`
and scoped key (`m177`), and `m176` proves it cannot read another app's data. The written
justification writes itself: zero application-specific code, every app a declarative contract,
and here is the gate. → [platform/06-contracts](../platform/06-contracts.md)

**Minor (1 pt) — the SSRF guard on the `http` engine.** Small, concrete, demonstrable: a mount
pointing at `169.254.169.254` is refused. Shows security judgement better than any WAF
configuration. → [security/04-network](../security/04-network.md)

*Considered and set aside:* the TypeScript→Rust cutover with shadow mode is the most mature work
in the project but hard to demonstrate live — better as an oral argument than a claimed module.

---

## Open — do these first

| Check | Worth |
|---|--:|
| Does `VaultProvider` talk to HashiCorp Vault? (credential layer, migration `060`) | 2 pts and the only cybersecurity module |
| What are `src/apps/ai/` and `src/apps/analytics/`? | Up to 4 pts from categories written off |

The AI category was dismissed because gaming modules need a game and we have none — but the
*LLM interface* major needs no game, and neither does the analytics dashboard major. Half a
morning of reading; six points in play.

---

## Out of reach

All of **gaming and UX** — every module requires a working game. That also removes the
AI-opponent module, tournaments, spectator mode and match statistics. **Blockchain**, none.

---

## Order of work

1. The three rejection criteria — nothing here matters if one fails. → [01-subject](01-subject.md)
2. The two open checks above.
3. Raise the **B** flags, run their gates, save a known-good `.env`.
4. Build screens for the **C** rows — by then you will know how many you actually need.

Raise flags early, not the night before: **off is the tested configuration.**

---

See also: [01-subject](01-subject.md) · [DEFENSE.md](../DEFENSE.md) ·
[quality/02-key-gates](../quality/02-key-gates.md)
