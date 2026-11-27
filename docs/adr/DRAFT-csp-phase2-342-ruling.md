# DRAFT. App CSP phase 2: static Report-Only frame/img/style first, generated connect-src only once fail-closed, no sink yet

- Status: proposed (draft, unnumbered). devil 2026-11-23: slice 1 PROCEED-WITH-CONDITIONS; generator PROCEED-WITH-CONDITIONS C342-1 to C342-8; connect-src enforce BLOCK; bridge violation sink BLOCK.
- Date: 2026-11-23
- Deciders: devil (ruling); osionos builder. Issue: osionos #342 (phase 2 of #314, ADR 0076).
- Full ruling: `/mnt/storage/dlesieur/scratch/csp342/RULING.md` (conditions C342-1 to C342-26)

## Context

References are to osionos develop d7460aa10, groot `origin/develop` cad7fc17 and `origin/main` fc8b03ad.

- The app policy is a Report-Only `map` in osionos `docker/services/node/nginx.conf:9-11`; only `frame-ancestors` is enforced (`:37-39`). Phase 1 S3 is not done (ADR 0076).
- Four builds COPY that file: osionos `Dockerfile.prod:69`, groot develop and main `infrastructure/docker/osionos/app.Dockerfile:175`, and the prod snapshot `deploy/dockerfiles/app.Dockerfile.groot-7ebe3935:175` (`deploy/web-main.yml:27`). Prod does not build from groot develop.
- Beta builds osionos develop with groot main's Dockerfile and only greps `<title>` before going live (`infrastructure/beta/update.sh:18,24,52`). groot's Dockerfile must build older osionos pins (D313-2, `app.Dockerfile:177-178`).
- The bundle gets env two ways: `define` from `loadEnv(mode, root, '')` (`vite.config.ts:55,67-80`) and `import.meta.env`, which is fed only from `.env` files (`app.Dockerfile:149-155`).
- Runtime origins the design missed: `data:` PDF frames (`FilePreviewModal.tsx:34,50`), generic `http(s)` embeds (nds `EmbedBlock.tsx:35,74`), PDF export fetches of any image URL that fail silently (`exportPdf.ts:26-37`), Giphy CDN download (`giphyApi.ts:73`), LiveKit https `/validate` next to wss (livekit-client 2.19.0) with the URL coming from bridge env (`bridge-rtc.mjs:27,82`).
- livekit-client puts `access_token` in the socket URL query, so a violation report can carry a room token.
- `/graph-studio/` sets its own `add_header`, so its worker runs with no policy (`app.Dockerfile:264-270`).

## Alternatives

- **The design as submitted (generator + one-line COPY swap, bridge sink, enforce in steps):** if osionos is ahead, beta and prod ship the committed DEFAULT render, whose connect-src names localhost, and every bridge call fails (cost 5). If groot is ahead, older pins stop building. An unauthenticated sink stores tokens and unbounded keys on the save path.
- **connect-src `https: wss:` (option A):** restricts nothing that matters; rejected as an end state.
- **Runtime `envsubst` (option C):** the policy input is not the bundle input; rejected.
- **In-app `securitypolicyviolation` listener posting through the session:** no new unauthenticated endpoint, but blind to workers, pre-boot and signed-out pages. It must be weighed in the sink review (C342-19).

## Decision

- Slice 1, buildable now, osionos only: static Report-Only `frame-src 'self' https: <loopback node>`, `img-src 'self' data: blob: https:`, `style-src 'self' 'unsafe-inline'`. The enforced header stays byte-identical (C342-26). Phase 1 and phase 2 directive sets are pinned apart (C342-9).
- Slice 2: generated connect-src in Report-Only, only with fail-closed skew in both directions, an image-build assertion, all four consumers updated, env provenance proven, input hygiene, and preview/sweep reading the render (C342-1 to C342-8).
- Not built: the sink, any enforced phase 2 directive, the frame-src generator half, `style-src-elem` enforcement.

## Consequences

- PROCEED-WITH-CONDITIONS: slice 1; slice 2; frame-src / img-src / style-src floor enforce, each held behind C342-10 to C342-13, C342-16, C342-20 to C342-24.
- BLOCK: connect-src enforce until C342-14 (LiveKit key + https, user-content and Giphy fetches, U-c/U-d/U-g, prod fixture, Report-Only field data) and C342-15. Sink until C342-17 to C342-19.
- Rollback: one directive per image, target = previous step. Open tabs and offline service-worker starts keep the old policy until reload or an online navigation (`sw.js:70,91,137-139`) (C342-21).
- Worst axis: cost on failure (5) of connect-src enforcement under build skew; confidence 2.
- Owed `.out-of-scope/` entries (not written; the ruling had a two-file limit): `csp-connect-src-scheme-wide.md`, `csp-runtime-envsubst.md`, `csp-third-party-report-sink.md`, `csp-frame-src-from-embed-denylist.md`. Each one's reopen fact is in RULING.md §8.
