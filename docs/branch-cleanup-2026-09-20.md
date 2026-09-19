# Branch cleanup — 2026-09-20

Stale branch refs removed after the repos reached `develop == main == origin` everywhere.
Every deleted branch tip is an ancestor of its repo's `main`, so no commit was lost; only the name
went away. Recreate any of them with the command in the last column (run inside that repo's checkout).

Teammates: your local branches are unaffected. `git fetch --prune` drops the stale remote-tracking refs.

## Remote branches deleted (tip == ancestor of origin/main, no open PR, unprotected, no CI reference)

| repo (path) | branch | full sha | recreate |
|---|---|---|---|
| Univers42/groot (`.`) | `docs/wiki-restructure` | `4e71c9cc5cb6c97298ef3545ec926214b44ebb8a` | `git push origin 4e71c9cc5cb6c97298ef3545ec926214b44ebb8a:refs/heads/docs/wiki-restructure` |
| Univers42/groot (`.`) | `feat/ide-full-mode` | `e93d3154ad7592cd8ba1396d2451a8fe22042b90` | `git push origin e93d3154ad7592cd8ba1396d2451a8fe22042b90:refs/heads/feat/ide-full-mode` |
| Univers42/groot (`.`) | `fix/osionos-live-databases` | `19cd22ba2f9d409c2b94790ac7afc394e64aa634` | `git push origin 19cd22ba2f9d409c2b94790ac7afc394e64aa634:refs/heads/fix/osionos-live-databases` |
| Univers42/groot (`.`) | `fix/team-vault-share` | `83afa526add92103c5af1e5ee419b1b1eca6384e` | `git push origin 83afa526add92103c5af1e5ee419b1b1eca6384e:refs/heads/fix/team-vault-share` |
| Univers42/osionos (`apps/osionos/app`) | `feat/caret-horizontal-block-nav` | `dad040c678ff12118cfd50fbe45f948f747e61a8` | `git push origin dad040c678ff12118cfd50fbe45f948f747e61a8:refs/heads/feat/caret-horizontal-block-nav` |
| Univers42/osionos (`apps/osionos/app`) | `feat/ide-full-mode` | `9cf704425d2aa19bf1e168e91be83bc7ceb1731b` | `git push origin 9cf704425d2aa19bf1e168e91be83bc7ceb1731b:refs/heads/feat/ide-full-mode` |
| Univers42/osionos (`apps/osionos/app`) | `feat/ide-monaco` | `fc2f6649a38a0c5e513981ecddf9f24d954ca92b` | `git push origin fc2f6649a38a0c5e513981ecddf9f24d954ca92b:refs/heads/feat/ide-monaco` |
| Univers42/osionos (`apps/osionos/app`) | `feat/perf-smoothness-polish` | `994524cc1be850e11111143f31a11bf8de437b38` | `git push origin 994524cc1be850e11111143f31a11bf8de437b38:refs/heads/feat/perf-smoothness-polish` |
| Univers42/osionos (`apps/osionos/app`) | `feat/social-network` | `ecc68a627f31a780768539a5fdc5dfa01df59810` | `git push origin ecc68a627f31a780768539a5fdc5dfa01df59810:refs/heads/feat/social-network` |
| Univers42/osionos (`apps/osionos/app`) | `refactor` | `bafc2eeb5fccb539a180accea6a553d2102c49db` | `git push origin bafc2eeb5fccb539a180accea6a553d2102c49db:refs/heads/refactor` |
| Univers42/osionos (`apps/osionos/app`) | `refactor_perf_and_mark` | `ce304561609570173680318f4a5de26232c309fc` | `git push origin ce304561609570173680318f4a5de26232c309fc:refs/heads/refactor_perf_and_mark` |
| Univers42/osionos (`apps/osionos/app`) | `restyle/warm-editorial-perf90` | `46ab514e4d4137f56e9d490e7277869b8d88a22e` | `git push origin 46ab514e4d4137f56e9d490e7277869b8d88a22e:refs/heads/restyle/warm-editorial-perf90` |
| Univers42/grobase (`apps/grobase`) | `feat/infra` | `5e57b6cefa4b12bbab50498f2e82bee61033154d` | `git push origin 5e57b6cefa4b12bbab50498f2e82bee61033154d:refs/heads/feat/infra` |
| Univers42/grobase (`apps/grobase`) | `feat/realtime-agnostic-zoo` | `d1de0d6a1d025787e640d1cbd1d45853fc0ec115` | `git push origin d1de0d6a1d025787e640d1cbd1d45853fc0ec115:refs/heads/feat/realtime-agnostic-zoo` |
| Univers42/grobase (`apps/grobase`) | `fix/block_bugs` | `d3aaab274b07349f1c237c7fc4fac7e7cffac6cb` | `git push origin d3aaab274b07349f1c237c7fc4fac7e7cffac6cb:refs/heads/fix/block_bugs` |
| Univers42/grobase (`apps/grobase`) | `fix/osionos-live-mounts` | `cba6d70fdaa4dabb983bc67d9600ab4f3adf663a` | `git push origin cba6d70fdaa4dabb983bc67d9600ab4f3adf663a:refs/heads/fix/osionos-live-mounts` |
| Univers42/grobase (`apps/grobase`) | `refactor/infra-k8s` | `8d8c76d7879724bede0ddec0f502ff63dd890eca` | `git push origin 8d8c76d7879724bede0ddec0f502ff63dd890eca:refs/heads/refactor/infra-k8s` |
| Univers42/born2root (`vendor/born2root`) | `feat/born2root-toml` | `7a434a2edeb819f3368d8a4432d821a4eb22f954` | `git push origin 7a434a2edeb819f3368d8a4432d821a4eb22f954:refs/heads/feat/born2root-toml` |
| Univers42/born2root (`vendor/born2root`) | `fix/deps-backend-aware-main` | `5ed68be4ad26869b9455c95c495eb821fad30412` | `git push origin 5ed68be4ad26869b9455c95c495eb821fad30412:refs/heads/fix/deps-backend-aware-main` |
| Univers42/born2root (`vendor/born2root`) | `fix/iso-md5-manifest` | `ffb5d3ee90241d0b60903b017e780c13544a1839` | `git push origin ffb5d3ee90241d0b60903b017e780c13544a1839:refs/heads/fix/iso-md5-manifest` |
| Univers42/born2root (`vendor/born2root`) | `perf/qemu-virtio-hardware` | `758748dc6e408654afb1e732232f3b39a7c9ab16` | `git push origin 758748dc6e408654afb1e732232f3b39a7c9ab16:refs/heads/perf/qemu-virtio-hardware` |
| Univers42/monkey-bot (`vendor/monkey-bot`) | `feat/smoke-bot` | `3a454e6d46f80de7b506482b7a759030d657a918` | `git push origin 3a454e6d46f80de7b506482b7a759030d657a918:refs/heads/feat/smoke-bot` |
| Univers42/notion-database-sys (`apps/osionos/app/src/shared/notion-database-sys`) | `feature/micro-service` | `b592a6166a707a2a92a87f52e321ea43f0efb439` | `git push origin b592a6166a707a2a92a87f52e321ea43f0efb439:refs/heads/feature/micro-service` |
| Univers42/scripts (`vendor/scripts`) | `hotfix` | `013b1d57e7840d7833294dd600a07222e049b8ca` | `git push origin 013b1d57e7840d7833294dd600a07222e049b8ca:refs/heads/hotfix` |
| Univers42/scripts (`vendor/scripts`) | `hotfix_track_binocle` | `cc8c5c47cb6e66cb2a3c15066dadda355dc95ee6` | `git push origin cc8c5c47cb6e66cb2a3c15066dadda355dc95ee6:refs/heads/hotfix_track_binocle` |

## Local-only branches deleted in `apps/osionos/app`

Extraction branches whose tips are ancestors of the corresponding package repo's pushed `main`.
Their history lives in those package repos, not in osionos.

| branch | full sha | preserved in |
|---|---|---|
| `extract/markdown-engine` | `e4e1540cba6f178fa4861fb813e2be947f05da21` | Univers42/markdown-engine `main` |
| `extract/outbox-ledger` | `cb368f5148a5d71c984dbaa9222543d69c5e855f` | Univers42/outbox-ledger `main` |
| `extract/perf-probe` | `a975756ca4d01500fe655fa3287c13d45443d2df` | Univers42/perf-probe `main` |

## Deliberately kept

- Every branch with commits not reachable from `main` (about 53 across the repos), including the three
  groot branches whose single commit is only patch-equivalent to `main` (`chore/bump-grobase`,
  `docs/dossier-back-en`, `fix/translate-doc-noisy-failure`).
- `osionos-mail` `baas-mail-mirror` and `prismatica` `ci/grobase-sdk-rename`: merged by ancestry, verified
  clean of open PRs after the ruling, left for a human to delete.
- `born2root` `develop` and `main` (protected). `develop` is an ancestor of `main`; a PR is needed to
  fast-forward it: https://github.com/Univers42/born2root/compare/develop...main
