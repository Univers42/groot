# Phase 1 plan gate — the devil's verdicts

Date: 2026-10-15. Plan: `docs/redesign/PLAN.md` at a0691844 (branch `redesign/brief`).
Sources read at the pins: osionos `fabe846b`, opposite-osiris `8559d6d`, grobase `8b9321a6`
(main checkout, read-only). Nothing was executed against any stack. GoTrue v2.188.1's source is not
vendored in this tree (it is built from the upstream tag, `infra/docker/services/gotrue/Dockerfile:35`),
so every claim about GoTrue internals below is marked UNKNOWN and turned into a test condition.

| Decision | Verdict | Worst axis |
|---|---|---|
| A — Phase 2 demo seed | **BLOCK** | Confidence 5 |
| B — Phase 5 verification and reset | **PROCEED-WITH-CONDITIONS** | Cost on failure 4 |

---

## Decision A — Phase 2 demo seed

### Steel-man

The plan is the right shape. It puts volume data in mounts and story data in pages, splits schema
from data, uses deterministic ids and a stored anchor, deletes nothing without a printed list and
`--yes`, builds locally first, and leaves the baas run to the human. It also opens with a spike
because it knows the view support is unproven. Most seeds are worse than this.

### What the source says

| # | Finding | Evidence |
|---|---|---|
| A1 | The bridge reads **every** mount with **one** tenant api-key and one tenant id, for all users | `bridge-api.mjs:166,174,563-567,593-603`; `docker-compose.yml:90` (`OSIONOS_BAAS_TENANT_ID` default `agency`) |
| A2 | The data plane refuses a key whose tenant is not the mount's tenant | grobase `data-plane-server/src/routes/helpers.rs:199` |
| A3 | ⇒ A mount in a tenant `demo-<uid8>` can **never** be displayed by the bridge. A mount in `agency` has **no** per-user data-plane isolation: the bridge's key reads it for every user, and `tenant_owned` drops owner scoping (`isolation.rs` `owner_scoped`). Per-user isolation is the bridge ACL alone | A1 + A2 |
| A4 | The mount ACL is **role-blind**: membership in any workspace that links a mount grants it, and the allowed ops include insert/update/delete/upsert/batch/ddl | `bridge-api.mjs:2591-2601` (`resolveAccessibleMount`), `:3055-3065` (`memberWorkspaceIds`, no role), `:2805` (`DB_OPS`), `:2905-2913` (ddl) |
| A5 | ⇒ Jules, a **viewer** member of Inès's workspace, gets full CRUD (and column DDL) on every demo mount: about 13 000 CRM and trade rows | A4 |
| A6 | Reading a shared page as a non-owner requires workspace membership, so Jules must be a member somewhere | `bridge-api.mjs:948-954,991-996` |
| A7 | Introspection lists only `public` unless the mount is `schema_per_tenant`, so tables in schema `trade` are invisible to database blocks | grobase `postgres/schema.rs:120` (and `:260`) |
| A8 | `POST /api/pages` takes no client id; the server generates it. UUIDv5 cannot reach pages, and a re-run creates duplicates unless the seed looks each page up first | `bridge-api.mjs:728-748` (`pageCreateRowFromPayload`, no `id`), `:3091-3104` |
| A9 | No bridge route writes `osionos_workspace_databases` (service_role-only RLS) or adds a non-owner `osionos_workspace_members` row | `models/osionos-workspace-databases-migration.sql:34-41`; bridge only reads it (`bridge-api.mjs:2518`); workspace create inserts only the owner row (`:3619-3622`) |
| A10 | `/admin/v1/databases` registers a DSN. The existing seed creates physical databases as the superuser through `docker exec`, and registers superuser DSNs | grobase `scripts/seed/osionos-extra-engines.sh:80,115-128,333,346` |
| A11 | The data plane's Postgres upsert is `ON CONFLICT … DO UPDATE`; there is no `DO NOTHING` path for Postgres | grobase `postgres/crud_build.rs:202` (sqlite alone has `DO NOTHING`, `sqlite/query.rs:176`) |
| A12 | 256 KB is the cap on `/admin/v1/migrate`. `/query/v1` allows 1 MB at 300 requests/min | grobase `kong.yml:645` vs `:721,737-743` |
| A13 | `/admin/v1/migrate` keys `_baas_migrations` by name, and runs all statements plus the marker insert in **one** transaction | grobase `postgres/schema.rs:62-100` |
| A14 | A local grobase cannot coexist with the running link stack: `backend-up` refuses while the relay runs. grobase sets 55 fixed `container_name`s, and the root project name is fixed. The running stack (link mode, up 2 h) is shared with the session in `/goinfre/dlesieur/wt-groot-e2e` | `infrastructure/makes/grobase.mk:64`; `grep -c container_name orchestrators/compose/base/*.yml` = 55; `docker-compose.yml:1`; `docker ps`, `git worktree list` |

### Ruling on the stated assumptions

1. **Local grobase available**: **false as stated** (A14). It is a scheduling decision for the
   user, not a technical step: it takes the shared stack away from another session.
2. **Ledger after `down`**: apply under a **unique name per application**, and never delete or
   edit the `_baas_migrations` row. That table belongs to grobase; editing it makes the server's
   bookkeeping lie to grobase's own tooling. A13 gives the clean mechanism: append the groot
   ledger `INSERT` as the last statement of the same request. The DDL, the groot ledger and the
   server marker then commit or roll back together, so a crash cannot leave them disagreeing. The
   groot ledger is the state; `_baas_migrations` becomes an append-only log.
3. **View support**: UNKNOWN. The planned spike is the correct remedy. It must also cover A7
   (non-`public` schema) and SQL views (A7's query may or may not list views).
4. **`tenant_owned` isolation for both engines**: **false in effect** (A1–A3). Gating on tenant
   applies to every engine (`helpers.rs:199` is engine-agnostic), but it isolates tenants, not
   users, and the bridge is a single tenant.
5. **Reset by manifest**: sound in principle. As written, it becomes dangerous once A3 forces the
   mounts into `agency` (see the next section).
6. **Batching and about 160 POSTs**: true in count, wrong in limits (A12). Pages need two passes
   (create, then PATCH with `[[page:<id>]]` links and relation ids), because ids are server-side
   (A8). That makes about 320 calls.

### The failure nobody mentioned

The only way to make the mounts displayable is to register them in the bridge's tenant (`agency`
by default, `docker-compose.yml:90`). Suppose the builder does that and keeps §5.4's reset ("delete
the demo tenant … listed in the manifest"). The manifest then names `agency`, and on baas
`seed:demo:reset --yes` deletes the tenant behind **every** osionos mount on the platform: the
`osionos-*` business, finance, restaurant and iot mounts the bridge serves to all users. It also
loses their keys. On the shared VM that is a one-way door, reversible only by restoring a
platform backup, which also loses everyone else's writes since.

Second: Jules as a viewer can `delete` Inès's CRM through `/api/databases/:dbId/tables/:t`
(A4/A5), so the brief's "only the owner can read them" is false on day one.

### Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | On baas the seed and reset hold service_role and the superuser on the platform postgres, GoTrue and the tenant registry |
| Reversibility | 4 | `DROP DATABASE`, tenant delete and GoTrue user delete on the VM are one-way, short of a full restore |
| Cost on failure | 4 | Deleting a non-demo tenant's mounts on a shared VM, and silent loss of the brief's isolation requirement |
| **Confidence** | **5** | The isolation model (A3), viewer isolation (A5), schema `trade` (A7), page ids (A8), "no service role" (A9) and the local backend (A14) are each contradicted by the source |

### Verdict A: **BLOCK**

§5.4's isolation and reset model is contradicted by the bridge and the data plane, and the
obvious fix opens a path to deleting a shared tenant.

**To lift it**, re-submit §5.4 with:

- **L1. Backend window.** The user approves, in DECISIONS.md with the date, an exclusive window
  for a local grobase (or confirms that the `wt-groot-e2e` session is finished). Done-when: the
  window is recorded, `make all SKIP_SYNC=1` runs from the redesign worktree with its own
  submodule checkout at the same pins, and after Phase 2 the link stack is restored and
  `make link-verify` passes.
- **L2. True isolation model.** §5.4 states that the demo mounts live in the bridge's tenant, that
  per-user isolation is the bridge ACL only, and that the data plane separates tenants, not users.
  `dm2` is rewritten into two parts:
  - (a) an outsider gets 403 from the bridge for every manifest mount id, on list, get, insert,
    update, delete, upsert, batch, ddl, sql-ro and txn;
  - (b) a key of another tenant gets refused by the query-router for those ids.
- **L3. Jules cannot reach the mounts.** Either the shared page lives in a second workspace that
  links no mount, with Jules a member only there, or an equivalent design. Done-when: dm2 asserts
  403 for Jules on every demo mount id and op, and the shared page still opens for him. The
  role-blind ACL (A4) is logged as a repair (R17, osionos, D-009) and handed over.
- **L4. Reset cannot delete what it did not create.**
  - Reset deletes no tenant at all.
  - It drops only databases whose name matches `^demo_[0-9a-f]{8}_(crm|activity)$`, **and** that
    are in the manifest, **and** whose `tenant_databases.name` matches.
  - It deletes GoTrue users only by manifest id **and** only with an email ending in
    `@arlet.example.com`.
  - A hard deny-list covers `agency`, `postgres`, `template*` and every non-demo name.
  - Done-when: a bats test plants each forbidden entry in a manifest and sees `reset --dry-run`
    exit non-zero. It is mutation-tested: remove the guard, and the test fails.
- **L5. Write and credential accounting.** One table lists every write with the credential it
  uses: physical database creation (who, and as which role), mount registration, link rows
  (service_role), Jules's membership (service_role), GoTrue users (admin), pages and object
  databases (the bridge as Inès). The "no service role" sentence (PLAN.md:382) is narrowed to
  pages and object databases.

**Conditions that apply once lifted** (acceptance criteria for the builder):

1. **Spike before bulk.**
   - One record per §5.3 mapping on the local grobase, with each view type the shot list needs
     rendered and screenshotted under `docs/redesign/spike/`.
   - The spike must include one table outside `public` and one SQL view, to settle A7.
   - Every fallback becomes a DECISIONS entry. No bulk generator runs before the spike's DECISIONS
     entries exist.
2. **All mount tables in `public`** (prefix `trade_`), unless the spike shows otherwise.
3. **Migration runner.**
   - Each application gets a unique server name, `<NNNN_name>.<up|down>.<seq>`.
   - The groot ledger row (version, file, sha256, direction, seq) is appended to the same
     `/admin/v1/migrate` request.
   - The runner never writes `_baas_migrations`, refuses an applied file whose sha256 changed, and
     refuses non-transactional DDL (`CONCURRENTLY`, `CREATE DATABASE`, `VACUUM`) in the dry run.
   - Each request is ≤ 256 KB.
   - Tests: up → down → up gives the schema diffs X, ∅, X; an edited applied file is refused; a
     migration with a failing last statement leaves **no** ledger row in either table.
4. **Page idempotency.** A deterministic seed key is stored on each page and looked up before
   create; the manifest maps seed key → server id. Done-when: a second `make seed-demo` issues
   **0** `POST /api/pages`, and the verify fingerprint is identical (bats).
5. **Mount-row idempotency.**
   - Rows are written with the `upsert` op (A11), not "DO NOTHING".
   - Seeded tables have no `DEFAULT now()` update column or trigger, or the fingerprint excludes it.
   - Done-when: the row checksum is equal after run 2.
   - Batches stay ≤ 1 MB and ≤ 300 requests/min on `/query/v1`, and the seed honours 429
     `Retry-After`.
6. **One manifest per target.**
   - The manifest path is keyed by the target (Kong URL + tenant id), git-ignored, and passes
     `make secrets-scan`.
   - `verify` and `reset` refuse when the manifest's target is not the current target.
7. **"Demo-tagged" is defined.** For osionos rows it is `owner_id ∈ {Inès, Jules}`; for mounts it
   is the name pattern in L4. `verify` lists any such row not in the manifest.
8. **Least-privilege DSNs.**
   - Each demo mount's DSN uses a login role limited to its own database, never `postgres` or
     `sa` (the `osionos-extra-engines.sh:346` precedent is not copied).
   - Done-when: through the mount, `select 1 from pg_authid` fails.
9. **Non-demo invariance.** Before/after counts of non-demo rows (`auth.users`, `tenants`,
   `tenant_databases`, `osionos_pages`, `osionos_workspace_members`) are equal across seed and
   reset (keep §8.1's test).
10. **People directory.** The demo users get `directory_opt_out` set, or a DECISIONS entry says
    why they are listed (AUDIT §4.3).
11. **baas run.**
    - The human runs it, after the Appendix A inventory shows the bridge's tenant on baas, no
      existing `demo_*` names, and a Mongo engine mounted.
    - The order is dry-run → reviewed diff → `--yes --target baas`, outside the backup and gc
      windows recorded in ADR 0002.

---

## Decision B — Phase 5 email verification and password reset

### Steel-man

Splitting GoTrue (tokens) from the gateway (policy) is correct. Tokens stay random, single-use and
hashed in the one component that already does it, and the browser never talks to GoTrue. The
gateway already holds the admin key and the mail path. Respond-before-lookup is the right cure
for the timing oracle, the per-address cap reuses a proven primitive (`auth-gateway.mjs:1007`),
and the one-vocabulary SMTP fix addresses the real R5 defect.

### What the source says

| # | Finding | Evidence |
|---|---|---|
| B1 | The age check runs **after** `/verify` has consumed the token. For `signup`, GoTrue has already set `email_confirmed_at`, so the gateway's 410 cannot undo a confirmation. "A platform change cannot lengthen it silently" is false | PLAN.md:509; flow PLAN.md:495-503 |
| B2 | `/login` awaits a failed-login alert **only when a profile exists**, before answering 401: a timing oracle outside the plan's enumeration scope. `/register` answers 409 for a taken email | `auth-gateway.mjs:919-929` (`localProfileExists` at :923), `:845-852` |
| B3 | GoTrue has MFA on; the gateway has MFA routes. Whether GoTrue v2.188.1 lets an aal1 recovery session `PUT /user {password}` for a user with a verified factor is UNKNOWN; recent GoTrue requires aal2 | grobase `auth-api.yml` `GOTRUE_MFA_ENABLED: "true"`; `auth-gateway.mjs:1180` |
| B4 | The local `apps/grobase/.env` sets `SMTP_HOST` to a Titan host (1 match, value not printed), and GoTrue takes `${SMTP_HOST:-mailpit}`. A local stack's GoTrue mails through Titan. The plan's bats test covers only the gateway | grobase `auth-api.yml:24-28` |
| B5 | The gateway's compose interpolation source is `--env-file ./.env.local`, which vault42 can populate. A "no override" render does not prove a populated seat is safe | `infrastructure/makes/docker.mk:12`, `grobase-link.mk:36`; `docker-compose.yml:524-530` (already `${SMTP_HOST:-mailpit}`) |
| B6 | Other GoTrue settings live in an optional `.env.gotrue`, so "no `GOTRUE_MAILER_OTP_EXP` is set" is unverified on baas | grobase `auth-api.yml:12-16` |
| B7 | The `osionos_*` schema lives in groot `models/`, not in the osionos repo. The new column is a groot migration applied to baas (human-run) | AUDIT §4.2; `models/osionos-bridge-migration.sql` |
| B8 | `verifyAppSessionToken` is synchronous and HMAC-only, and about 27 bridge modules import it. A per-request DB check either goes inside it (async ripple) or behind a cache whose staleness is the revocation latency | `bridge-api.mjs:403-445`; `grep -l verifyAppSessionToken scripts/*.mjs` |
| B9 | `iat` has 1 s granularity, so a token minted in the same second as the reset is ambiguous | `bridge-api.mjs:405` |
| B10 | Other browsers' GoTrue access JWTs stay valid for up to 3600 s wherever only the signature is checked (Kong, PostgREST, data plane) | grobase `auth-api.yml` `GOTRUE_JWT_EXP: 3600` |
| B11 | `token_hash` in a query string lands in nginx access logs and in `Referer` | PLAN.md:496,500 |
| B12 | Today `requestPasswordRecoveryEmail` is awaited inside the handler. Moved after the response, an unhandled rejection crashes Node (≥ 15) | `auth-gateway.mjs:414-432,948-956` |

### Ruling on the stated assumptions

1. **`/verify` returns the `*_sent_at` fields**: UNKNOWN (no GoTrue source here). With condition 1
   below, the design stops depending on it.
2. **A newer `generate_link` kills the older token**: plausible, UNKNOWN. pr2 already tests it;
   keep that test.
3. **`logout?scope=global` revokes every refresh token**: plausible, UNKNOWN. It does **not** revoke
   live access JWTs (B10); see condition 9.
4. **Respond-then-work removes the oracle**: yes, for `/recover` and `/resend`. Losing work on a
   restart is acceptable. Unbounded and unguarded work is not (B12).
5. **The bridge check is cheap and in osionos**: half true. The check is in osionos; the column is
   groot's (B7); the cost is a cache-staleness trade (B8).
6. **Tests can never reach Titan**: **false** as proven (B4, B5).

### The rejected alternative (a gateway-owned token table)

**The rejection holds.** GoTrue remains the only party that can confirm an email, set a password
and revoke its own sessions, so a gateway table still calls GoTrue for every state change. It
would add a second token store to the shared platform database, a human-run migration on baas,
and a lookup surface, all without removing the dependency. The one real gain, an exact
per-purpose TTL enforced **before** consumption, costs about 20 lines without the table (condition
1).

The answer changes if any of these turns out true:
- pr2 shows that an MFA user cannot complete a recovery through `/verify` and the admin password
  update does not revoke sessions;
- grobase's GoTrue is replaced;
- `GOTRUE_MAILER_OTP_EXP` is set below 86 400 by another app on the platform.

### The failure nobody mentioned

- An attacker learns which emails have accounts from `/login`'s response time (B2), whatever
  `/recover` does.
- A user with TOTP enrolled can never reset a forgotten password (B3, if GoTrue enforces aal2).
- Any anonymous `POST /api/auth/recover` during a GoTrue outage crashes the gateway once the work
  moves after the response (B12). That is a site-wide sign-in outage triggered from outside.

### Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | Every site and osionos user; about 27 bridge modules; GoTrue settings shared platform-wide |
| Reversibility | 2 | The code reverts in one step; the additive column and any sent mail do not |
| **Cost on failure** | **4** | A reset or revocation bug is an account-takeover window or a lockout |
| Confidence | 3 | The design is sound. The GoTrue internals (assumptions 1–3, B3) are UNKNOWN but testable before merge |

### Verdict B: **PROCEED-WITH-CONDITIONS**

The design is sound, and every UNKNOWN can be proven by a local test before merge. These
conditions are the acceptance criteria:

1. **Age checked before consumption.**
   - The gateway signs each link: HMAC over `(token_hash, type, exp)` with a dedicated
     `AUTH_LINK_SIGNING_KEY` (named in `.env.example`, reused for nothing else).
   - A bad signature or a past `exp` gets 410 **without calling GoTrue**.
   - Done-when: a unit test sees the GoTrue mock receive 0 calls for an expired or tampered link.
     PLAN.md:509 is corrected.
2. **No token in a URL a server sees.**
   - The token travels in the fragment (`#token_hash=…`), and both pages send
     `Referrer-Policy: no-referrer`.
   - Done-when: after pr1 and pr2, `grep` of the nginx and web access logs finds no token value.
3. **Resend keeps the password.** pr1: sign up, resend, confirm with the **second** link, then the
   password chosen at sign-up signs in. This guards against `generate_link(signup)` overwriting the
   password.
4. **MFA reset.**
   - pr2 has a variant for a user with a verified TOTP factor: either the reset completes, or the
     page asks for the code and reaches aal2 before `PUT /user`.
   - The other outcome (MFA users cannot reset) needs the user's decision in DECISIONS.
5. **Enumeration stated honestly.**
   - The §7.1 row lists `/availability`, `/register` 409 and `/login` (B2).
   - The `/login` alert send moves after the response, and pr3 covers `/login` with the same
     tolerance.
   - Keeping `/register` 409 and `/availability` is a dated DECISIONS entry by the user.
6. **Bounded after-response work.**
   - One queue with a maximum length, at most 2 concurrent SMTP sessions, overflow dropped and
     audited, every rejection caught.
   - Tests: the GoTrue mock throws after the 202, and the next request is still served; 10 000
     queued requests do not grow the queue past its maximum.
   - A `Caveat:` line names lost-on-restart.
7. **One per-address bucket.**
   - `/recover` and `/resend-verification` share the counter `keyHash(lowercased trimmed email)`,
     taken before any lookup.
   - pr4 alternates the two endpoints, and the 4th request sends no mail.
   - The victim-lockout residual (an attacker can spend a victim's 3/h) goes in DECISIONS.
8. **`sessions_valid_after`.**
   - The migration is a groot `models/*.sql` file, service_role-only, in the runner's order, and
     `make models-grants-verify` passes. Applying it on baas is human-run.
   - The check lives inside the single verifier (`bridge-api.mjs:425`), so every module inherits it.
   - Unit tests: a token minted 1 ms before `valid_after` gets 401 and one minted 1 ms after is
     accepted. This needs a millisecond claim or a stated rule for the same second (B9).
   - Behaviour on a failed lookup is chosen and tested; the staleness bound is a `Caveat:` and is
     measured in pr2.
9. **The residual is named.** §7.1 states that other sessions' access JWTs live for up to 3600 s
   at signature-only services. pr2 asserts what is revoked: their refresh returns 4xx, and the
   bridge answers 401.
10. **Logout without an access token.** After a reload, `POST /api/auth/logout` with only the
    cookie revokes it: replaying the old cookie on `/api/auth/refresh` gets 401.
11. **Titan unreachable, proven at run time.**
    - `tests/e2e/run.sh` refuses `pr*`/`dm*` unless the running gateway's effective `SMTP_HOST`,
      and for a local backend `mini-baas-gotrue`'s `GOTRUE_SMTP_HOST`, is the Mailpit service.
    - A bats test plants `SMTP_HOST=smtp.titan.email` in a temporary `.env.local` and sees the
      refusal. It is mutation-tested.
12. **No test users on baas.**
    - `pr*` refuses to run while the link relay points at a remote backend.
    - Test users use a reserved domain and are deleted at teardown, so OD1's leak is not repeated.
    - Like Decision A, this needs a local-backend window (L1).
13. **The verification default flips with its tests.** `AUTH_REQUIRE_EMAIL_VERIFICATION=true` lands
    in the same change that moves `ac1-new-account` through Mailpit, announced to the session that
    shares the stack.
14. **The platform knob is checked.** A preflight reads the effective `GOTRUE_MAILER_OTP_EXP`
    (compose plus `.env.gotrue`) and fails if it is set below 86 400. On baas the check goes into
    Appendix A's human-run inventory.

---

## Claims in PLAN.md §5/§7 that the source contradicts

| PLAN line | Claim | Source says |
|---|---|---|
| 387 | Mounts in a tenant of her own, `demo-<uid8>` | The bridge uses one tenant key (`bridge-api.mjs:166,174`); the data plane refuses other tenants (`helpers.rs:199`). Such a mount is never displayed |
| 391 | dm2 proves refusal by the data plane | The data plane cannot tell Inès from an outsider: both reach it through the bridge's single key |
| 390 | A viewer sees only the page that names him | A role-blind mount ACL gives him CRUD on every linked mount (`bridge-api.mjs:2591-2601,2805,3055-3065`) |
| 332 | Trade tables in schema `trade` | Introspection reads `public` only (`schema.rs:120`) |
| 365, 380 | UUIDv5 ids (for pages) | `POST /api/pages` ignores a client id (`bridge-api.mjs:728-748`) |
| 379 | `ON CONFLICT DO NOTHING` | The Postgres upsert is `DO UPDATE` (`crud_build.rs:202`) |
| 379 | Kong's 256 KB cap for rows | 256 KB is `/admin/v1/migrate`; `/query/v1` is 1 MB at 300/min (`kong.yml:645,737-743`) |
| 381-382 | No service role | Link rows and memberships are service_role-only (`osionos-workspace-databases-migration.sql:34-41`; `bridge-api.mjs:3619-3622`) |
| 509 | A platform change cannot lengthen verification | The check runs after GoTrue has confirmed the email |
| 512 | New column, osionos repo | The `osionos_*` schema is groot `models/` (AUDIT §4.2) |
| 484 | No `GOTRUE_MAILER_OTP_EXP` is set | Not in compose; `.env.gotrue` on baas is unread (`auth-api.yml:12-16`) |
| 524 | Interpolation instead of hard defaults | `SMTP_HOST` is already interpolated (`docker-compose.yml:524`). The defect is the key names, and the source is a vault-pullable `.env.local` |
| 513 | No account enumeration | `/login` timing (`auth-gateway.mjs:923`) and `/register` 409 (`:851`) enumerate |

## Records owed

The caller limited writes to this file, so the ADRs the three-gate rule asks for are **owed, not
written**:
- an ADR for Decision A's isolation and reset model, after the re-submission;
- an ADR for Decision B, a public auth surface under PROCEED-WITH-CONDITIONS, with conditions 1–14
  in its Consequences.

Both should be numbered after the main checkout's untracked ADR 0002–0004.

---

## Decision A — re-ruling after re-submission (2026-10-15)

Re-read: PLAN.md §5.2–5.4 (lines 300–497) and §8.1 (668–705).

| Lift item | Status | Where |
|---|---|---|
| L1 exclusive local-backend window | **Open.** It is the user's decision (§9 Q2) | PLAN.md:483-492 |
| L2 isolation stated as bridge-ACL-only; dm2 split | Met | PLAN.md:370-382, 690 |
| L3 two workspaces; Jules only in "Finance review"; R17 handed over | Met | PLAN.md:384-391, 310-311 |
| L4 no tenant deleted; triple match; deny-list; mutation-tested bats | Met, with gap G1 | PLAN.md:393-404, 694-697 |
| L5 write and credential table; "no service role" narrowed | Met | PLAN.md:406-421 |
| Conditions 1–11 | Folded in, with gaps G2 and G3 | PLAN.md:423-481, 692-698 |

**Verdict now: BLOCK, on L1 alone.** Once the user records L1 in DECISIONS with its date, the
verdict becomes **PROCEED-WITH-CONDITIONS**. The conditions are the plan's own §5.4/§8.1
acceptance criteria plus the four gaps below, and none needs another hearing.

**Remaining gaps** (each is an acceptance criterion):

- **G1 — Reset teardown order is unspecified** (PLAN.md:394-402). The reset deletes rows with an
  `owner_id`, but `osionos_workspace_databases` link rows and the `tenant_databases` registration
  have no owner, and the per-database login roles are not mentioned.
  - The order must be: unlink rows → deregister the mount → drop the database → drop the role.
  - Role names get the same triple match as databases.
  - Done-when: after reset, the `tenant_databases` name lookup returns 0 rows for the demo names,
    and a fresh `make seed-demo` registers the mounts with 201, not 409.
- **G2 — The least-privilege probe must not depend on sql-ro** (PLAN.md:420, 698). Bridge sql-ro
  is off unless `OSIONOS_SQL_RO=1` and the query-router allows it (`bridge-api.mjs:2877-2882`). The
  probe connects with the mount's own role.
  - Postgres: `select 1 from pg_authid` fails.
  - Mongo: reading another database fails.
  - A probe that cannot run reports SKIP and fails verify; it is never green.
- **G3 — dm2(b) fixture** (PLAN.md:382, 690). The second tenant and its key are created by the
  test and deleted at teardown, locally only. The spec refuses to run against baas.
- **G4 — Cosmetic: the §8.1 table is split.** The `run.sh` paragraph (PLAN.md:682-683) sits
  inside it, so rows `st1`–`st4` (684+) render as stray text. Move the paragraph below the table.

Risk once L1 is recorded:

| Axis | Score |
|---|---|
| Blast radius | 3 |
| Reversibility | 3 (the baas steps stay human-run) |
| Cost on failure | 3 |
| **Confidence** | **3 (worst)**: the view support is still unproven, and the spike gates it |
