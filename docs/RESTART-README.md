# groot — restart README (owner machine)

How to use: open Claude Code in the repo root and paste everything below the rule, or run

    claude "$(sed 1,7d docs/RESTART-README.md)"

It names no secret value; the same text lives at ~/README.md and ~/.local/state/groot/TOMORROW.md on the owner VM.

---


Read .claude/rules/* first (prompt-contract, run-safely, risk, quality-bar). Decide from facts
(git log, docker ps, command output) and cite file:line. Never print values from .env*, secrets/,
~/.config/42ctl. Agents never run `make vault42-team-push` or any 42ctl push (secrets off-box is
human-only, it needs the passphrase). Plain git pushes only, never force. Commit message "updated",
no trailer. Verify any pasted handoff against `git log` / `git branch -a` before acting on it.

## Where things stand (verified 2026-09-19 23:49)
- This machine is the OWNER and the reference: `make healthcheck` exit 0,
  `bash scripts/gen-local-env.sh --check` = in sync (7 keys), postgres osionos_pages = 391 = the vault seed.
- Git: every repo has develop == main == HEAD, all pushed, every submodule pointer reachable on its remote.
  groot 1e623bf6; osionos fc2f6649 (checked out on develop); grobase cba6d70f (= main; branch fix/osionos-live-mounts removed, see docs/branch-cleanup-2026-09-20.md);
  vendor/scripts 2bb05b4f (develop merged, both committed virtualenvs dropped, 149 files); calendar aed2172;
  monkey-bot 3a454e6; osionos-ui 476fb34; notion-database-sys cc0c8c1.
  Exception: vendor/born2root develop is PR-protected -> main 758748d, develop a2cc983 (PR pending, human).
- Vault (42ctl shared env univers42/groot/prod, sealed to the env key): 55 files = every *.env*/*.secrets +
  secrets/ (all engine seeds, checksum-clean, captured 21:26; grobase-certs.tar.gz; mongo keyfile;
  HANDOVER-TEAM.md). The 6 *.local files are private to the owner. Env secrets present: infra/S3_KEY,
  infra/S3_SECRET (needed for the two >4 MiB archives), team/env-local (OSIONOS_BRIDGE_EMAIL_HASH_SALT /
  OSIONOS_BAAS_API_KEY / VITE_BAAS_*). 4 members hold an active key (`env keys ls`).
- ~/.config/42ctl/ (keystore, 20 KB) + the passphrase are the ONLY things in neither git nor the vault.
  groot-vault42-handbook.team.html (102 KB, untracked, never committed) is in neither unless sealed as
  team/handbook.html — check: `scripts/vault42-ctl.sh env secret get --org univers42 --project groot --env prod team/handbook.html | wc -c`.
- Added yesterday (on develop/main): scripts/vault42-team.sh (make vault42-team-push / vault42-team-pull,
  VAULT42_SOURCE=team), scripts/vault42-ctl.sh (ad-hoc 42ctl, honours FT_PASSPHRASE),
  scripts/gen-local-env.sh --check|--sync (7 derived keys), scripts/lib/envfile.sh (put_env),
  scripts/tests/{gen-local-env,envfile}.bats (23 tests; `docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/<file>`),
  handover page https://claude.ai/code/artifact/8ee3b43b-fe2f-44bf-b214-98ac3a1525a3 (private; share from its menu).

## The three bugs that made the first `make all` "completely buggy" — root causes, fixed in code, do not re-investigate
1. Empty workspaces + 502 on /api/pages/all. A fresh `make all` restored the git snapshot
   (apps/grobase/data-snapshots, 2026-07-28) whose osionos_pages lacks cover_position/template_surface; the
   bridge's column list got 400 and surfaced 502. Fix: models-migrate runs inside `make all`
   (infrastructure/makes/pipeline.mk:5, scripts/apply-models-migrations.sh, IF NOT EXISTS), and when secrets/
   holds the vault seeds scripts/restore-if-empty.sh replays them (current schema) instead of the snapshot.
   Manual fix on any machine: psql the two files models/osionos-page-cover-position-migration.sql and
   models/osionos-admin-migration.sql, then reload the app in a private window (old page ids are cached).
2. Kong 401 / app anon token mismatch. Root ./.env.local never travels (*.local is private) and
   gen-local-env.sh never overwrote an existing one, so a stale SB_KONG_KEY survived every pull. Fix:
   `gen-local-env.sh --sync` runs in `make all` (env-local-ensure) and after `vault42-team-pull APPLY=1`;
   `--check` names drift by KEY, never a value. VITE_BAAS_REALTIME_TOKEN is NOT derived (seed-live-demo mints
   a tenant token into it) — never add it to the mapping.
3. Teammate "no manifest for project groot". The personal `42ctl push` seals to the caller alone. Fix: the
   team-scoped push/pull (VAULT42_ORG=univers42, VAULT42_ENV=prod in infrastructure/makes/repo.mk).
   With VAULT42_SOURCE=team a failed pull aborts `make all` instead of silently self-generating secrets and
   pinning the data volumes to them (the LOCAL-mode trap).

## Morning routine on THIS machine (already provisioned)
1. `make healthcheck` -> exit 0. If containers are down: `make all` (restore-if-empty is a no-op on a populated stack; it never wipes).
2. `bash scripts/gen-local-env.sh --check` -> in sync (7 keys). If it names drift: `bash scripts/gen-local-env.sh --sync`.
3. `docker exec mini-baas-postgres psql -U postgres -tAc 'select count(*) from osionos_pages'` -> 391 or more.
4. `git status --short` clean; `git fetch --all` in the parent and submodules; merge teammates' work before starting.
5. End of day, if data changed: `make vault42-seed`, then (human) `make vault42-team-push`.

## Fresh machine or teammate (in order; never wipe before the seed check)
git clone (develop); git submodule update --init --recursive; put the keystore at ~/.config/42ctl;
`make vault42-team-pull` (dry run: expect 55 files incl. postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb);
`make vault42-team-pull APPLY=1 BACKUP=1` (expect "[vault42-team] laid N team key(s) over .env.local");
`(cd secrets && sha256sum -c --quiet SHA256SUMS && echo SEEDS-OK)`; only then `make ffclean CONFIRM=1`;
`VAULT42_SOURCE=team make all`; `make healthcheck`; `--check`; count 391. Details: the handover page / secrets/HANDOVER-TEAM.md.

## Open items (human decisions)
- born2root: PR main -> develop (protected branch): https://github.com/Univers42/born2root/compare/develop...main
- Before deleting this machine: copy ~/.config/42ctl + passphrase off-box, seal the handbook, copy ~/.ssh/id_ed25519,
  and PROVE the restore on another box first (dry-run pull listing 55 files, then make all + the three checks there).
- osionos local branches extract/markdown-engine, extract/outbox-ledger, extract/perf-probe share no history with
  develop (their content lives in packages/*). Delete with `git branch -D` or leave.
- vendor/scripts: md-to-pdf/theme.css kept main's version over develop's — unreviewed choice.
- 42ctl (your own tool): `env push --private` does not re-kind an already-stored path; `env` has no file removal command.
- Optional: a fresh-start make target gated on a proven dry-run pull; a manifest-vs-files check before pushes.

## Guardrails learned
- Ad-hoc 42ctl calls need FT_PASSPHRASE exported, else "os error 6":
  printf 'vault42 keystore passphrase: ' >&2; stty -echo; read -r FT_PASSPHRASE; stty echo; echo; export FT_PASSPHRASE
  (unset it afterwards). Type long commands on ONE line: a terminal wrap turned `--env prod` into a command.
- The push preview is a candidate list, not the manifest; `scripts/vault42-ctl.sh env files --org univers42 --project groot --env prod` is the authority.
- DynamoDB on this box is legitimately empty -> vault42-seed always reports "skipped: dynamodb".
- Submodules have no git identity; commit in them with `git -c user.name=LESdylan -c user.email=dev.pro.photo@gmail.com`.
- Parked on this host only (disposable): ~/.local/state/groot/secrets.pre-reseed.20260919-2126, env.local.bak.2026-09-18, ~/sh42 (hellish clone).
