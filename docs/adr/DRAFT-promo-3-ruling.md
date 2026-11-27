# DRAFT: Promotion 3, osionos develop → main, bridge then web

- Status: proposed (devil ruling PROCEED-WITH-CONDITIONS, 2026-11-24)
- Full ruling: /mnt/storage/dlesieur/scratch/promo-3/RULING.md

## Context

- The range runs from main 0e85b24fd to develop 1bb05f95e: 12 commits, fast-forward possible.
- CI is green on the exact sha (run 45301824274). The bundle-pin, quality, canvas, bridge and markengine steps all ran; none was skipped.
- Beta has served `osionos-beta/web:1bb05f95e86c` against the production bridge for about 10 h (ADR 0040).
- The bridge diff is #240 only:
  - `scripts/bridge-pages-from-markdown.mjs`;
  - the engine bundle at 4b9d703;
  - `bridge-api.mjs` +19/−3, the route mount plus `authorizePageCreate` and `insertPageRow` at `:4473-4483`;
  - the PAT entry at `bridge-pat-middleware.mjs:96`.
- No DDL, no new runtime env name.
- Engine 4b9d703 is engine main, with green engine CI. It carries S1 (da93b98) and S1-9 (4b9d703).
- M240-4 artifact (`tests/bench/markdown-import/results.jsonl`): 251 documents, worst 22 ms at 64 KiB. The S1 shapes take 0.14–0.34 ms and the S1-9 shapes 0.78–0.82 ms.
- Every commit subject is "updated". The source is the convention at `apps/osionos/app/CLAUDE.md:81`, not a hook: there is no hook, no `core.hooksPath` and no `commit.template`. Main already holds 616 such commits, and no workflow reads subjects.
- Unit B (`feat/cover-size-client` 73855ec26) is not on origin, does not contain develop, has no CI run and has not served on beta.
- Unknown when this was written:
  - production parse latency;
  - whether the probe account has a sole-member workspace;
  - the live PAT path, which is test-only.

## Alternatives

| Option | Cost |
|---|---|
| Unit B rides promotion 3 | A rebase, CI run and beta soak stand in front of the S1-8 deadline (2026-11-30). A Unit B rollback would also roll back S1. |
| Reword "updated" subjects first | A force-push. It voids the CI run and 10 h of beta on the exact image. |
| Joint bridge + web swap | One failure becomes unattributable, and recovery needs a double rollback. |
| Hold the web until #240 is live | S1-8 would wait on #240, which the S1 ruling forbids. |
| **Bridge first, watch, then web; web proceeds even if a #240-only cause rolls the bridge back** | Two windows. Each rollback lands on a pairing that has already run. |

## Decision

- Cut at 1bb05f95e as a plain fast-forward, re-checked right before the push, with no develop CI running.
- Swap the bridge first, under live #240 probes (401, 413 `markdown_too_large`, 404 missing parent, 201 → delete, 64 KiB `heading_ws` timing, 429) and a 10-minute watch. Then swap the web, with headers, bundle, browser checks and a 10-minute watch.
- Unit B ships alone as web-only promotion 4.
- The "updated" subjects do not block the fast-forward.

## Consequences

The conditions PR3-1 to PR3-25 are the acceptance criteria. They cover:

- the cut, the push and CI:
  - the fast-forward re-check, with no develop CI running;
  - main CI green before the swap;
- builds and images:
  - images built through the deploy tools, with the engine pin recorded (S1-8);
  - an image smoke inside the built bridge image;
  - rollback images kept until 2026-12-01;
- a value-digest env diff with 0 added, 0 removed, 0 changed;
- rollback scripts written before either swap;
- fixed-order #240 probes with no workspace creation and no PAT minting;
- a create-and-delete probe on the refactored POST /api/pages;
- page-list kill bar: pre-swap p50 + max(5 ms, 10 %), with the post-promotion-2 reference at 142.1 ms;
- web checks:
  - headers byte-identical to the promotion 2 capture;
  - flags baked empty;
  - zero console errors;
- a log check at T+60 min;
- rollback triggers, with a #240-only cause rolling back the bridge only;
- a session revoke after every sign-in;
- the groot pin made in a `/mnt/storage/dlesieur/wt` worktree last.

A web rollback re-exposes S1, so re-promotion still owes 2026-11-30. Pages created through #240 survive a bridge rollback as ordinary pages. Whether `apps/osionos/app/CLAUDE.md:81` keeps the "updated" convention, which conflicts with groot `rules/pull-requests.md`, is left to the user.
