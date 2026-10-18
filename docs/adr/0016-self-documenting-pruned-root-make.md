# 0016. Self-documenting, pruned root make

- Status: accepted
- Date: 2026-10-18
- Deciders: devil (risk ruling, conditions C1-C12); user (Q1: delete `up`, `up-infra`,
  `up-local`, `local`; Q2: delete `baas-verify.mk`)

## Context

- The root make system was 37 modules, 223 targets, in `infrastructure/makes/` (now
  `utils/mk/`). `make help` listed only the targets whose description sat on the line after the
  target, and a hand-written `.PHONY` list in `common.mk` had drifted from the targets.
- A large share of the targets could not succeed any more:
  - the HashiCorp Vault / Fly system was retired for vault42 (`vault*.mk`, `fly.mk`, `env.mk`);
  - `up`, `up-infra`, `up-local` start postgres, kong, gotrue and others that are in no compose
    file (the backend is the standalone `apps/grobase` stack, project `mini-baas`);
  - `grobase-up` and friends need the `grobase-site` service and a context that are gone;
  - `baas-release.mk` needs `apps/grobase/Dockerfile`; `gourmand.mk` needs scripts, an app and a
    container that no longer exist.
- `baas-down` and `baas-down-lean` ran `down -v` on project `mini-baas`, which is the live
  backend's data volumes, with no confirmation.

## Decision

### Convention

Every rule in a module carries its summary on the target line and is grouped by section.
`utils/scripts/make-help.awk` builds `make help` and `make help-<target>` from the markers, and
`.PHONY` is derived from them:

```make
##@ Backend (grobase)
import-push: ## Re-verify an import dir, then rsync it to the data center
## Usage: make import-push ID=<import-id> [DEST=host:/path] [DRY=1]
	@...
```

- Summary at most 80 characters, imperative, names the danger (DESTRUCTIVE, needs CONFIRM=1).
- `## ` lines under the target are extended text, shown by `make help-<target>`; a target that
  reads user-passed variables starts them with `## Usage:`.
- Sections come from one fixed list. Why-comments stay plain `#` above the target.
- No hand-written `.PHONY` line in `utils/mk/`.

### Deletion criteria

A target was deleted only when one of these held:

| | Criterion |
|---|---|
| a | stub: recipe only prints `[skip]` or runs `true <verb>` |
| b | broken: needs a file, service, image or container that no longer exists |
| c | duplicate: same recipe as a kept target, or owned by grobase's own Makefile |
| d | retired system: HashiCorp Vault, Fly, the old mini-baas release flow |
| e | helper whose only caller was deleted |

The per-target list with letters is in the commit body of
`refactor(make): delete dead targets`. `compose-wait` moved unchanged to `grobase.mk`, next to
its only remaining caller `frontends-up`.

### Include order

`Makefile` includes `common.mk` (variables read at parse time) and `pipeline.mk` (so `make all`
prints first), then every other `utils/mk/*.mk` in name order. A new module loads itself.

## Consequences

- Devil conditions C1-C12, as far as this change carries them:
  - C4: `make-all-footprint.bats` asserts the retired images are not pulled for scope `all`
    (`run grep ...; [ "$status" -eq 1 ]`) and that scope `vault` is refused; the test was shown
    to fail with the kong pull restored.
  - C7: `vault42-seed` help no longer cites the deleted `vault.mk`.
  - C11: the `agency-content` container fix is its own commit.
  - C12: this ADR and `.out-of-scope/root-grobase-wrappers.md`.
  - The other conditions (C1-C3, C5, C6, C8-C10) are in the devil's ruling, not restated here.
  - Before every commit the `make -pq` database was diffed against the pre-change base: after
    the deletions only deleted rules and variables differ, after the fixes only the fixed recipes,
    after the marker conversion nothing.
- Fixes in kept targets: `e2e` passes `E2E_SPECS`; `docker_reclaim_dangling` counts the volumes
  it removed (it always printed 0); `docker-prefetch-images` scope is `all|frontends`;
  `agency-content` writes to `mini-baas-postgres`.
- The CI step `make vault-status db-password-check` is gone: `vault-status` baked a missing
  context and `db-password-check` was a stub that passed vacuously.
- `common.mk` lost every variable with no remaining reader; `COMPOSE_*_INFRA` were folded into
  the three `COMPOSE_*_SERVICES` lists with identical final values.
- Residual, known and not fixed here:
  - `make` on a deleted name now fails with "No rule to make target"; no script or workflow
    calls one (grep of the tree at this commit); docs naming `make baas-security-scan`
    (`QUALITY-SECURITY-TOOLING.md:97`, `.semgrepignore:3`) are stale.
  - Anything outside this repo that ran a deleted target (shell history, other checkouts) is
    unchecked.

## Follow-ups

- `apps/osionos-electron/local-edition/install.sh:54` and `release.sh:55` call the deleted
  `make local`.
- `docker-compose.local.yml` header still describes `make up-local`.
- `docker-compose.yml:705` comment, the compose service `grobase-site-audit`, and the
  `vault` / `grobase-site` targets of `docker-bake.hcl` are dead.
- `tools/seeds/seed_wiki_content.py` lines 508, 525, 729 carry seed text naming deleted targets.
- `tools/seeds/*gourmand*` are orphaned by the removal of `gourmand.mk`.
- `secrets-ensure` pushes and pulls asymmetrically; a separate change.
