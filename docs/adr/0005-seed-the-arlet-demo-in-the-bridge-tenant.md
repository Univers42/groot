# 0005. Seed the Arlet demo into the bridge's tenant, with a reset that only deletes what it made

- Status: proposed (blocked on one input: the user's exclusive local-backend window, L1)
- Date: 2026-10-15
- Deciders: devil (rulings of 2026-10-15, `docs/redesign/verdicts/phase1-devil.md`); the user
  records the backend window and runs the baas seed

## Context

- The redesigned site's captures and its 75-second tour are recorded from a demo account. That
  account needs real data: a CRM in PostgreSQL, an activity store in MongoDB, pages, and a second
  user (PLAN.md §5.2–5.3).
- The data plane separates tenants, not users. The bridge holds one tenant key
  (`bridge-api.mjs:166,174`), and the query-router refuses any other tenant's key (`helpers.rs:199`).
  Per-user isolation of mount data is the bridge's workspace ACL alone.
- That ACL is role-blind (`bridge-api.mjs:2591-2601,3055-3065`). A viewer member of a workspace
  that links a mount can write to the mount. This is repair R17, handed to osionos.
- The first version of the reset deleted by tenant. On the shared baas that is a path to deleting
  a tenant other people use. The verdict was BLOCK (phase1-devil.md §Verdict A).
- Running a local grobase on this seat conflicts with another session's link stack. Who may run
  it, and when, is the user's decision.

## Decision

- **Where the data lives.** The demo mounts `demo_<uid8>_crm` (PostgreSQL) and
  `demo_<uid8>_activity` (MongoDB) are registered in the bridge's tenant. Each has a login role
  limited to its own database. A DSN never uses `postgres` or `sa`.
- **Two workspaces.** Inès owns "Arlet — Operations", which links the mounts, and "Arlet — Finance
  review", which links none. Jules is a viewer member of the second only. The shared page lives
  there.
- **Reset deletes only what seed made.** It deletes no tenant. A database is dropped only when
  three conditions hold: its name matches `^demo_[0-9a-f]{8}_(crm|activity)$`, it is in the
  manifest, and its `tenant_databases.name` matches. GoTrue users are deleted by manifest id and
  only with an `@arlet.example.com` address. A deny-list (`agency`, `postgres`, `template*`,
  `mini_baas*`) is checked first. The teardown order is: pages and object databases, link rows,
  the mount registration, the database, then its role.
- **Every write names its credential** (PLAN.md §5.4 table). service_role is used for
  registration, link rows, membership and GoTrue users. Pages are written by the bridge as Inès.
- **One manifest per target**, keyed by Kong URL and tenant id, and git-ignored. `verify` and
  `reset` refuse a manifest whose target is not the current one.
- **The baas run is human-run:** dry run, then a reviewed diff, then `--yes --target baas`.

## Alternatives considered

- **A dedicated demo tenant**: it needs a second tenant key in the bridge, which holds only one.
  That is a platform change, not a seed.
- **Jules as a viewer of the operations workspace**: with the role-blind ACL he could write to the
  mounts, so the demo would ship the R17 defect.
- **Reset by tenant**: one wrong id deletes a shared tenant.

## Consequences

- Verdict: BLOCK on L1 alone. The isolation and reset model (L2–L5) was accepted on re-submission.
  Once the user records the window in DECISIONS.md with its date, the verdict becomes
  PROCEED-WITH-CONDITIONS with no further hearing.
- The acceptance criteria are conditions 1–11 of phase1-devil.md and the gaps G1–G3:
  - **G1:** after reset, the `tenant_databases` lookup returns 0 rows for the demo names, and a
    fresh seed registers the mounts with 201, not 409.
  - **G2:** the least-privilege probe connects with the mount's own role and does not use sql-ro.
    A probe that cannot run is SKIP, and SKIP fails verify.
  - **G3:** the second tenant used by dm2(b) is created and deleted by the test, locally only.
- A spike comes before bulk generation: one record per mapping, one table outside `public`, and
  one SQL view. Each fallback is a DECISIONS entry.
- What this does not cover: anyone holding the bridge's tenant key can read every mount in that
  tenant. That is a platform limit, stated in PLAN.md §5.4, and not something the seed can fix.
- Until L1 is recorded, Phase 2 does not run, and the captures and tour that depend on it
  (Phase 4) show placeholders. The site states this ("The recording is made from the demo
  account and lands with it").
