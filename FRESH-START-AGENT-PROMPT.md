# Fresh-start agent prompt

Paste the block below to a Claude Code agent on a **fresh Ubuntu machine** to bring the whole project
up from scratch with `make all` using your vault42 / 42ctl identity. (Full runbook: [`README.md`](README.md),
[`DATA-MIGRATION.md`](DATA-MIGRATION.md).)

---

```text
You are a Claude Code agent. Bring up the ft_transcendence ("Track Binocle") project from scratch on
this fresh Ubuntu machine and confirm it's healthy with all data restored. It's a Docker-first
monorepo (TypeScript + Go + Rust) — EVERYTHING runs in containers; never install project dependencies
on the host. The single entry point is `make all`, which is self-provisioning and idempotent.

## 1. Verify prerequisites first
- Docker installed and running, with its data-root on a LARGE disk — the build pulls ~50 images +
  runs 6 DB engines and will exhaust a small system disk. Check `docker info | grep "Root Dir"` and
  `df -h`; relocate the data-root to a big volume before continuing if needed.
- git installed.
- The vault42 identity is present at ~/.config/42ctl/ — you need BOTH files: keystore.v42 (~498 B,
  the private key) AND contract-default.tok (~182 B, the tenant contract). These are the ONE thing
  not in git or the vault (they ARE the vault key). If missing, ask the user to copy the whole dir
  from a machine that has it:  scp -r OLD_HOST:~/.config/42ctl ~/.config/
  Verify:  ls -l ~/.config/42ctl/keystore.v42 ~/.config/42ctl/contract-default.tok

## 2. Secrets / credentials
- vault42 passphrase: Grobase-Vault-2026!  — pass it via the FT_PASSPHRASE env var so the vault pull
  is non-interactive (don't rely on the hidden prompt).
- The cert-trust step needs ONE sudo (to install the local CA so HTTPS is trusted). You can't type
  the user's sudo password, so have the user run `sudo -v` first to cache it.
- App login after it's up:  dev.pro.photo / Osionos123!

## 3. Bring it up
    git clone --recursive https://github.com/Univers42/groot.git ft_transcendence
    cd ft_transcendence
    sudo -v                                          # user enters sudo password once (for CA trust)
    FT_PASSPHRASE='Grobase-Vault-2026!' make all

`make all` will: sync submodules to latest -> pull every .env secret from vault42 -> generate + TRUST
the local TLS CA -> start the grobase backend with all 6 engines (Postgres, MySQL, Mongo, MSSQL,
DynamoDB, MinIO) -> restore the data into every engine (fail-safe: only when empty, never wipes) ->
build + start the frontends -> healthcheck -> print clickable trusted-HTTPS URLs. First run is slow
(image pulls + frontend builds).

## 4. Verify success — the data is the point; confirm ALL 6 engines
    make healthcheck    # must pass
    docker exec mini-baas-postgres psql -U postgres -d postgres -tAc "SELECT count(*) FROM osionos_pages"   # expect 350
Expected restored data: postgres osionos_pages=350 - mysql `ops` schema populated - mongo
activity.events~30000 - mssql `finance`~5 tables - dynamodb 3 tables - minio~67 objects.
Then open https://localhost:4322 (website) and https://localhost:3001 (osionos editor), sign in with
the login above — both must load over GREEN (trusted) HTTPS, no warning.

## 5. If something fails
- Vault pull / "Unauthenticated: missing auth metadata" -> BOTH keystore.v42 AND contract-default.tok
  must be in ~/.config/42ctl/ (the key alone is not enough). Passphrase is exactly
  Grobase-Vault-2026!. The 42ctl image (docker.io/dlesieur/42ctl:latest) is public/auto-pulled.
- Backend won't start / disk full -> confirm Docker data-root is on the big disk; inspect
  `make -C apps/grobase up EDITION=migrate` and `docker compose logs`.
- Data didn't restore -> `make all` restores ONLY into empty engines. To force from the committed
  snapshot:  cd apps/grobase/data-snapshots && CONFIRM=1 ./restore-databases.sh
- Anything transient -> just re-run `make all`; it's idempotent and self-heals (skips the backend if
  it's already up).

## 6. Notes
- `make all` uses the lean `migrate` edition (all 6 engines, no monitoring extras). Everything-on:
  `make all GROBASE_EDITION=full`.
- Full runbook in-repo: README.md (quick start) + DATA-MIGRATION.md.
- Secrets are vault42/ctl42 ONLY (HashiCorp Vault is retired). Never commit secrets.
- The restored data is whatever was last snapshotted + committed on the source machine.
```

---

## Notes for the human

- This is the **with-vault path** (you have `~/.config/42ctl/`). Without it, `make all` still works in
  zero-config local mode (grobase self-generates secrets) — but the agent gets a *fresh* stack, not
  your restored data.
- The only two human moments: entering the **sudo password** once (so HTTPS is trusted), and copying
  the **`~/.config/42ctl/` dir** once. `FT_PASSPHRASE` makes everything else autonomous.
- Before migrating, re-snapshot on the source machine if you've added test data since the last one:
  `bash apps/grobase/data-snapshots/snapshot-databases.sh`, then commit/push grobase + bump the root gitlink.
