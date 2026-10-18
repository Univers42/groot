# 0017. The vault42 CLI beside the old path

- Status: accepted (the old path stays until R1-R6 below are done)
- Date: 2026-10-18
- Deciders: devil (conditions G1-G7)

## Context

- Univers42/scripts publishes `vault42/`, a CLI that moves env files, secrets and docker volumes
  through 42ctl from one config file. groot's own path does the same with `scripts/vault42-team.sh`,
  `apps/grobase/scripts/vault/ctl-env.sh` and the `vault42-team-*` / `vault42-*-all` targets.
- The CLI has been proven only against its own fake 42ctl. No credentialed call has run, so it
  cannot replace the old path yet: verify the new path against the old before deleting the old.

## Decision

- `utils/vault42.conf` (targets `secrets` and `volumes`), `utils/mk/vault42.mk` (section
  `Secrets (vault42)`) and `utils/scripts/vault42-post-pull.sh` wire the CLI in. `vendor/scripts`
  is pinned at cc0d2525, the first commit carrying `vault42/`.
- The old path is unchanged except one `--private 'apps/*/vendor/*'` in `vault42-team.sh` (G3) and
  the executable bit on `scripts/vault42-push-guard.sh`, which the CLI executes as `pre_push`.
- The `secrets` target does not name `stage_unscanned_as`: the old path stages nothing, so a first
  push from the new path must produce the same tree.
- The `shared` list holds the 12 engine dump names ruled shared on 2026-10-18; `secrets/my_vault`
  is left out because its owner has not decided, so a push stops and asks.
- The `volumes` target has no `private`: the archives exceed 42ctl's 4 MiB private-file ceiling.

## Conditions (devil)

| | Condition | Proven by `scripts/tests/vault42-make.bats` |
|---|---|---|
| G1 | `vendor/scripts` is pinned at a commit that is an ancestor of `origin/main` | `git merge-base --is-ancestor cc0d2525 origin/main` |
| G2 | the old and the new path pass the same `--private` set | "G2: old vault42-team.sh push and new make vault42-push" |
| G3 | `apps/*/vendor/*` is private on both paths | "G3: apps/x/vendor/y/.env.example ..." and G2 |
| G4 | an applied pull runs the real post-pull hook, with only FT_PASSPHRASE, and no lock error | "G4: make vault42-pull APPLY=1 ..." |
| G5 | `APPLY`, `YES`, `ALL` count only from the make command line | "G5: ..." (two tests) |
| G6 | `VAULT42_ENV`, `VAULT42_ORG`, `VAULT42_PROJECT` are refused, from either source | "G6: ..." and its control |
| G7 | no absolute path in the config; a missing volumes root fails before docker runs | "G7: ..." (three tests) |

## Retiring the old path (operator checklist)

None of these can run from an agent shell; each needs the operator's keystore.

- R1 `make vault42-status` exits 0.
- R2 Right after `make vault42-team-pull APPLY=1`, `make vault42-diff` reports no differences.
- R3 The pull previews of the old and the new path list the same files.
- R4 The C18 drill: a first live push to a throwaway env, `pull --apply` into an empty directory,
  `diff -r` empty.
- R5 The first real `make vault42-push` to groot/prod is the pending republish (pinned image,
  `my_vault` decision); then the drill and `sha256sum -c` all OK.
- R6 `secrets-ensure` treats CLI exit 5 (missing credential) as fatal (C7), and one CI `make all`
  run is green.

When R1-R6 hold, delete `vault42-team-*`, `vault42-*-all`, `scripts/vault42-team.sh` and the
duplicated overlay in it; `utils/scripts/vault42-post-pull.sh` repeats that overlay until then.

## Consequences

- Two paths do one job until R6. `vault42-push` says so in `make help-vault42-push`.
- The make guard on `VAULT42_*` covers the make entry only: calling the CLI directly with another
  config still goes anywhere.
- Not verified: any live vault call, and whether the `pre_push` guard behaves identically when the
  CLI runs it with no credentials (it runs in the test fixture).
