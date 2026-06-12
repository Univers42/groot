# RELEASE — how a Grobase BaaS version ships

Maintainer doc. The pipeline is `.github/workflows/baas-release.yml` (monorepo
root); these are the human steps around it.

## Versioning

- **One umbrella version** for the suite: the 16 bake images + binocle-nano/one
  images and binaries all carry the same `X.Y.Z`.
- **SDK** (`@mini-baas/js`) tracks the suite's major.minor; its patch floats
  (npm requires monotonic versions).
- **realtime-agnostic** versions independently (it's an upstream we pin, like
  `kong:3.8`). Bump procedure below.
- **Tag namespace**: `baas-vX.Y.Z` in the monorepo (bare `v*` belongs to other
  products). Pre-releases: `baas-vX.Y.Z-rc.N` — the workflow marks them
  prerelease and skips the `latest` tags.
- **Scope (v1.0)**: images and binaries are **linux/amd64** only (the binocle
  Dockerfiles target x86_64-musl). arm64 is a v1.1 item.

## Pre-tag checklist (local, Docker-first)

```sh
make release-check            # automated part of this list
make verify-all               # all milestone gates — hard floor:
                              #   m21 (helm parity) · m28 (packages parity)
                              #   m32 (footprint budgets) · m37 (nano)
                              #   m40–m45 (one) · m46 (share-pools isolation)
make check-secrets            # no hardcoded secrets
# CI green on the release commit · SDK: npm run build && npm test (apps/baas/sdk)
# git status clean · .env untracked
```

Gate context notes (learned 2026-06-13):
- **m32/m33 measure LIVE RSS** — run them on a fresh tier-shaped stack
  (`make up PACKAGE=<tier>` after a `down`), not on a long-running box that
  load tests have inflated (one untrimmed Debezium CDC stream
  `mini_baas.public.outbox_events` alone held 250 MB of redis after a bench
  storm — its trim policy is a v1.1 item).
- **m46** needs `SHARE_POOLS_PROBE=1 SHARE_POOLS_EXPECT=0|1` (live probe).
- **m39** runs on the scale shape only (`DATA_PLANE_SHARE_POOLS=1`); on the
  base per-tenant-pool shape it SKIPs by design.

## Cut the release

```sh
# 1. rc first — proves the whole pipeline end-to-end
git tag -a baas-v1.0.0-rc.1 -m "Grobase BaaS v1.0.0-rc.1" && git push origin baas-v1.0.0-rc.1
#    → watch the run: gates → bake-publish → binocle → github-release → monitor

# 2. the real thing
git tag -a baas-v1.0.0 -m "Grobase BaaS v1.0.0" && git push origin baas-v1.0.0
```

## Post-publish checklist

- [ ] `monitor` job green (pulls the published binocle-one, container healthcheck passes)
- [ ] **GHCR packages set to PUBLIC** (first push lands private — Settings →
      Packages → change visibility; easy to forget)
- [ ] **Clean-VM smoke** (~20 min, fresh Ubuntu with only git/curl/make/docker):
      Path A `curl …/baas-vX.Y.Z/install.sh | sh` → run → CRUD via curl;
      Path B clone → `make quickstart` → `make health` green →
      `bash scripts/phase1-smoke-test.sh`. Save the transcript to `artifacts/`.
- [ ] **SDK publish** (manual at v1.0): in `apps/baas/sdk` —
      `npm run build && npm version X.Y.Z && npm publish --access public`
      (`.npmrc` sets ignore-scripts, so build explicitly). Verify:
      `npm view @mini-baas/js@X.Y.Z`.
- [ ] Release notes: lead with the SKU table below; numbers cite their artifact.

## SKU lineup (release-notes template)

| SKU | One line | Measured |
|---|---|---|
| **binocle-one** | Your PocketBase, smaller — accounts/OAuth2-PKCE/TOTP MFA/files/SSE/admin `/_/` in one static binary | 6.41 MB · ~2.2 MiB RSS · gates m40–m45 |
| **binocle-nano** | Headless embedded data plane (SQLite, CRUD+graph+keys+SSE) | 5.1 MB · 2.0 MiB RSS vs PocketBase 30.1 MB · 13.1 MiB (`artifacts/nano-vs-pocketbase.json`) |
| **self-host basic** | Node-free Pi-class CRUD (Rust `/data/v1`) | ~460 MiB · 11 svc |
| **self-host essential** | The default: full product, aggregates | ~950 MiB · 19 svc |
| **self-host pro** | Multi-engine + realtime + storage + txns | ~1.4 GiB · 28 svc |
| **self-host max** | Everything incl. DDL + analytics | ~3.5 GiB · 41 svc |

## Bumping the realtime pin

1. Tag `vX.Y.Z` in `Univers42/realtime-agnostic` → its release workflow builds
   the binary + GitHub Release, then publishes `dlesieur/realtime-agnostic:X.Y.Z`
   (+ GHCR mirror).
   **Gotcha (bit v0.2.0 and v0.2.1):** the publish job needs repo secrets
   `DOCKER_HUB_USERNAME` / `DOCKER_HUB_TOKEN` — without them the binary/Release
   jobs go green but the image job fails at login. Add the secrets
   (`gh secret set … --repo Univers42/realtime-agnostic`), then re-run just the
   failed job: `gh run rerun <run-id> --failed`.
2. Bump the pin in `docker-compose.yml` (`image: dlesieur/realtime-agnostic:…`).
   The service keeps its `build:` context, so local stacks build from source
   regardless of the pin — the pin only governs pull-only deployments.
3. Re-verify: `make verify-m44` (SSE) + `bash scripts/phase11-realtime-websocket-test.sh`.

## Standalone-repo note

`Univers42/mini-baas-infra` (the standalone product repo) is currently a stale
sync target; v1.0 ships from the monorepo (`baas-v*` tags). Syncing the
standalone repo and moving the release home there is a v1.1 item.
