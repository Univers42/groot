# Status ledger

> **Status:** Verified · 2026-09-15
> **Evidence:** reflects the status block of every page as written
> **Sources:** this wiki

One row per page. **Verified** means we checked it and the page says how. **Unverified** means
we have not, and the page says how to check and what breaks if it is wrong.

Update this table whenever a page's status block changes. It is the working list.

---

## Pages

| Page | Status | Blocking gap |
|---|---|---|
| README · ONBOARDING · DEFENSE · STATUS | Verified | — |
| platform/01-overview | Verified | — |
| platform/02-planes | Verified | — |
| platform/03-data-plane | Partial | Operation envelope not enumerated against `/engines` |
| platform/04-control-plane | Partial | `verify_cache` TTL unknown |
| platform/05-realtime | Partial | Default bus (`inprocess` vs `irc`) unconfirmed |
| platform/06-contracts | Verified | — |
| platform/07-isolation | Verified | — |
| platform/08-engines | Partial | Capability table transcribed from READMEs, not from `/engines` |
| security/01-model | Partial | Fine-grained ABAC flags off; unclear if needed for the demo |
| security/02-proofs | Verified | — |
| security/03-known-weaknesses | Verified | — |
| security/04-network | Partial | Is Kong's `:8000` an external surface anywhere? |
| operations/01-bring-up | Partial | Which edition `make all` raises (`migrate` not in the list) |
| operations/02-flags | Verified | — |
| operations/03-deployment | Verified | — |
| operations/04-troubleshooting | Verified | — |
| operations/05-secrets | Partial | Is a vault42 instance with our tenant running? |
| quality/01-gates · 02-key-gates | Verified | — |
| product/01-apps | Verified | — |
| product/02-osionos | Partial | Relationship with `notion-database-sys` unconfirmed |
| product/03-opposite-osiris | Partial | **Privacy Policy / ToS existence unverified** |
| product/04-repos | Partial | What is actually inside the delivered perimeter |
| project/01-subject | Unverified by nature | Source is private; re-check on each subject version |
| project/02-modules | Partial | Four open checks worth ~6 points |
| project/03-team | **Template** | Facts not held anywhere; fill with the team |
| project/04-glossary | Verified | — |

---

## Open checks, by payoff

Ordered by what they unlock, not by effort. Each one is minutes.

| # | Check | Command | If it goes the wrong way |
|---|---|---|---|
| 1 | Privacy Policy / ToS exist | inspect `apps/opposite-osiris` | Project rejected outright |
| 2 | Commits from all members | `git shortlog -sn --all` | Project rejected outright |
| 3 | Browser console clean | open all six frontends with DevTools | Project rejected outright |
| 4 | Does `VaultProvider` talk to HashiCorp Vault? | read `crates/data-plane-pool/` credential layer; migration `060` | 2 points and the only cybersecurity module |
| 5 | What are `src/apps/ai/` and `src/apps/analytics/`? | read both | Up to 4 points from categories we wrote off |
| 6 | Is `RUST_DATA_PLANE_FORWARD=1` set anywhere? | `grep -rn "RUST_DATA_PLANE_FORWARD=" scripts/env/ .env*` | The Rust data plane receives no traffic in production |
| 7 | Which edition does groot's `make all` raise? | `make editions`; compare with the root Makefile | `migrate` is not in grobase's edition list |
| 8 | `verify_cache` TTL | `crates/data-plane-server/` | Window during which a revoked key still works |
| 9 | Default realtime bus | `realtime-server` assembly | Whether the deployment is single- or multi-node |
| 10 | Operation envelope | `GET /engines` on a running stack | Exact limits of what clients can ask for |

---

## Resolved

Kept so nobody re-opens them.

| Question | Answer | How |
|---|---|---|
| Who picks a mount's isolation strategy? | A field in the contract: `"isolation": "shared_rls"` | Read `infra/config/contracts/website.json` |
| How is the vault key bootstrapped? | Generated locally by `42ctl keys init`; enrolment needs an invite from whoever runs the vault42 instance | 42ctl README |
| Is the realtime workspace in git? | Yes | `git ls-files infra/docker/services/realtime/` |
| How many engines? | Seven by default, eight with DynamoDB, plus two dialects | `crates/data-plane-pool/README.md` |
| Which flags are on in production? | orgs, RBAC hierarchy, environments, groups, invites, self-serve, app channels, email OTP | `deploy/fly/boot.sh` |

---

## Known documentation drift

`apps/grobase/CLAUDE.md` is the best source available and has been wrong five times on
verifiable details: the engine count, an edition that does not exist (`migrate`), a renamed
submodule, a directory it said was untracked when it was tracked, and a file path. Treat it as
authoritative *after* checking, not instead of checking.

---

See also: [catalogue](README.md) · [defense map](DEFENSE.md)