# DRAFT. The prod bridge moves from main-0e85b24f to release-branch 016fa51d0 (signed gone), after a TB17 probe fixed to survive its own post run

- Status: proposed (draft, unnumbered). devil 2026-11-27: PROCEED-WITH-CONDITIONS SG1–SG14.
- LIVE 2026-11-27 14:39:21Z as track-binocle/osionos-bridge:main-016fa51d (d30c43ae752f); TB17 post, 10-min watch and SG5 clean (DEPLOY-NOTES 14:39:21Z). Rollback logs/rollback-bridge-016fa51d.sh.
- Date: 2026-11-27
- Deciders: devil (ruling); operator (deploy). Implements `DRAFT-connector-trusted-browser-ruling.md` D3, TB12, TB13 and TB17.
- Full ruling: `/mnt/storage/dlesieur/scratch/bridge-gone/RULING.md`

## Context

- osionos main tip 06a8b69b1 carries #240 and is not promotable. So the release is 0e85b24fd (live)
  plus a cherry-pick of 69cda7f4a, which gives 016fa51d0.
  - The patch-id is the same for both: `498d86e6…`.
  - The diff is 3 files, +57/−12. No env var, schema or route changes.
- The new behaviour reaches only revoked rows (`scripts/bridge-machines.mjs:113-114`). An unknown
  row, a bad signature and a stale or replayed ts still get one `notPaired()` 410.
- `test-bridge` on 016fa51d0: 5315 tests, 5308 pass, 0 fail, 7 skip
  (`scratch/bridge-gone/test-bridge-full.out`).
- The owner's connector runs the old code (d9bc375ca). It deletes machine.json on any 410
  (`packages/osionos-node/heartbeat.mjs:76-79`). Its row is live and takes the unchanged path.
- The probe as drafted cannot record TB14 on the post run. `tb17-probe.mjs:52` passes no `onGone`,
  so the node branch's `await onGone()` (`heartbeat.mjs:96`) throws after the archive.
- Unknown when this was written:
  - whether the edge on `:10000` adds a per-request header outside the probe's `VOLATILE` set (SG2
    measures it);
  - the CI result on the `release/**` push.

## Decision

- Promote 016fa51d0 through `deploy-bridge-main.sh` with `ON=release/bridge-signed-gone`, under
  tag `main-016fa51d`. SUMMARY and DEPLOY-NOTES carry the branch.
- The TB17 probe inserts one row, revoked from the start, and deletes it by
  id + name + `revoked_at IS NOT NULL`.

## Alternatives considered

- **Tag override in the deploy tool first.** Deferred. It changes the overlay sed and the `OLD8`
  parse (`deploy-bridge-main.sh:17,62`) on the eve of a swap. No consumer resolves `main-<sha>`
  against `origin/main`.
- **Probe with a full pairing on the probe account.** Rejected:
  - it creates a live, mintable row;
  - it consumes an OTP;
  - it proves nothing extra, since the heartbeat reads only `revoked_at`.
- **Promote main.** Rejected: #240 was rolled back live on 2026-11-24.

## Consequences

- SG1–SG14 are the operator's acceptance criteria. The connector half ships only on the SG13 post
  record.
- Every later bridge promotion asserts that the signed gone is in its source (SG12). Without that
  check, a main build lacking 69cda7f4a would silently leave removed machines paired.
- Once the connector half ships, rolling back below 016fa51d0 is allowed but degrading. Removed
  machines then keep their open sockets until those close. Re-promote promptly.
