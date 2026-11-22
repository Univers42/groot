# 0077. Page media is signed at render behind fail-open, a foreign path is signed only for a page its owner belongs to, and the bare form closes only after an attributing log shows no in-app bare reader

- Status: accepted. devil 2026-11-22: steps 2–4 PROCEED-WITH-CONDITIONS D233-1–12; secret-only 5a PROCEED-WITH-CONDITIONS D233-13; `MEDIA_URL_ENFORCE=true` BLOCK, lifts on D233-14–20.
- Date: 2026-11-22
- Deciders: devil (ruling); osionos builder + operator (live with it). Issue: Univers42/osionos#233 (dup #235), grading groot#171.
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-233.md`

## Context

All references are to osionos `origin/develop` 483c5b0f4.

- Signing, verification, rotation and the enforce switch are on develop (`scripts/bridge-media-sign.mjs:24-50`, `scripts/bridge-media.mjs:51-67,163-164`). `node --test tests/bridge/bridge-media-signed.test.mjs` gives 12/12.
- No client calls the sign route (`git grep "uploads/sign" -- src services packages` → 0). `MEDIA_URL_*` is in no compose file. The groot ops docs say it is unset in prod (`docs/ops/production-golive-verdict-2026-11-04.md:41`).
- A foreign path is signed when it is a substring of any page the caller can read (`bridge-media.mjs:98,110`). The caller's own page is always readable (`bridge-api.mjs:1458-1460`). Proved with a scratch repro under enforce: an account holder signs a victim's planted path and passes auth.
- The bare-read log carries counts only (`bridge-media-sign.mjs:56-66`), so it cannot attribute readers.
- The DB views render covers in the notion-database-sys submodule with no URL seam (`GalleryView.tsx:110`, `BoardCardHelpers.tsx:49`, `FeedView.tsx:161` @ d2c39cdd).
- AI describe and Ask-AI fetch with the caller's token (`services/osionos-ai/src/media/describe.ts:54`, `runs/attachments.ts:27`), so a teammate's image is a bare read today and a 403 under enforce.
- The service worker never caches `/api/` (`public/sw.js:134`). Published `/p/` snapshots drop media and covers (`scripts/bridge-publish-snapshot.mjs:36,204`). Avatars use a separate public route (`scripts/bridge-avatar.mjs:57-58`).
- Unknown when this was written: which env file the live bridge reads, and whether beta has a bridge of its own (memory says it shares prod).

## Decision

The client signs bridge-upload URLs at render. Signing is fail-open: a 503 turns it off for ≥ 10 min with no retries. Batches are keyed by own-vs-pageId. Lifetimes are server-relative. Signed links are never written back to stored content. Issue screenshots are signed in the already-authorized issues GET. Every export states that it carries no media. The bridge signs a foreign path for a page only when the path's owner is that page's owner, a member of its workspace, or a collaborator. The secret can go live first, alone. The bare form closes only after the census is complete on prod main, the log attributes readers, and 7 days show no in-app bare read.

## Alternatives considered

- **The plan as written (one `{pageId, paths}` per frame, then enforce once the count-only log looks quiet)**: it leaves every gallery, board, feed and profile cover of another page unsigned. It cannot tell an old client from an attacker. It keeps the planted-path bypass, so enforce protects only against people without an account.
- **Enforce now, fix readers as they break**: it blanks the submodule DB views and the AI's teammate reads for every user on prod and beta at once, because the two share one bridge.
- **Declare page media a capability URL and close #233 as won't-do**: an honest option. It costs the groot#171 access-control sub-item, which would have to be re-worded rather than claimed.

## Consequences

- The builder owns D233-1–12 on develop. The operator owns D233-13 (with the user's go) and D233-14–20 before any enforce flip.
- The submodule seam and pin bump become a precondition of enforce, so the unpushed-pin trap applies.
- Reverse this ruling only if the bridge stops signing foreign paths by content substring (for example, an upload bound to a page at write time). D233-12 would then be replaced.

## As built (osionos develop 183188ee4, 2026-11-22)

- D233-1–12 are met on develop. Gates: typecheck, lint and quality rc 0; canvas 6476/0; bridge 5160/0.
- A security review of the branch found three defects, and each was fixed before landing:
  - Unsigned client with no key: `GET /api/capabilities` now reports `mediaSign`, true only when a media key is set. The client signer stays off until the bridge reports it, and the bridge strips `exp`/`kid`/`sig` only when a key exists.
  - The export note no longer claims that only members can open the media.
  - A workspace owner without a member row now counts as a member of that workspace.
- Stricter than the decision: collaborators are not counted, because page POST does not check that a collaborator is a member. Under enforce, a non-member collaborator's upload will not be signed for other readers. Before D233-14, either add a membership check or re-rule this point.
- A new enforce precondition: a member can still plant another member's content-addressed path, and use the signed GET to learn whether that path exists. This must be closed before `MEDIA_URL_ENFORCE=true`, along with D233-14–20.
- CI on 183188ee4 failed one census test: CI checks out the nested `vendor/` submodule (a VS Code extension) that local worktrees leave empty. Fixed in 95ed6dcc by skipping `vendor/` in the census scan.
- Live: nothing changed. The secret (D233-13) is not set, so signing stays off, and enforce stays off.
