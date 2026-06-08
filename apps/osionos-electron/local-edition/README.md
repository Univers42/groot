# osionos — Local edition (run it fully on another Ubuntu)

A **self-contained, local-only** install: the editor + a **lean backend** (database, auth,
pages) all on one machine, over plain **HTTP on `localhost`**. No cloud, no Fly Vault, no TLS
certs, and **none** of the heavy distributed `mini-baas` plane. Real local accounts (login is
enforced), data persists in a local Postgres.

## What runs (lean ≈ 12 containers, vs ~45 for the full dev stack)
`postgres · redis · kong · gotrue · auth-gateway · postgrest · osionos-bridge` (+ `db-bootstrap`,
`project-db-init`, `local-runtime-secrets` one-shot init, + `mailpit`, `pg-meta`).
**Excluded:** the whole `mini-baas-*` zoo (trino/iceberg/minio/mongo/mysql/debezium/…), the
website, mail, calendar, the web app, and the TLS proxy.

The Second Brain **graph** runs from the note layer (local pages) and **Database mode** from local
pages (notion-database-sys) — so the absent mini-baas costs you only the optional cross-engine
"data layer," nothing else.

## Prerequisites on the target machine
- **Ubuntu x86-64**, 22.04 or 24.04.
- **Docker Engine + compose plugin**, and **internet** (images are pulled from Docker Hub; nothing
  is built locally). Install Docker: <https://docs.docker.com/engine/install/ubuntu/> then
  `sudo usermod -aG docker $USER` and re-login.
- This **repo present** (it carries the lean compose, the local-secret scripts, and the DB
  migrations). No Node/pnpm, no Fly token, no certs.

## Install (one command)
```bash
bash apps/osionos-electron/local-edition/install.sh
```
It: checks Docker → pulls the lean images from Hub → `make local` (generates local secrets, starts
the lean stack on **http://localhost:4000**) → installs the desktop app from `dist-local/`.

> Don't have the artifacts yet? Build them first (on any build machine):
> `bash apps/osionos-electron/build.sh --local` → `dist-local/osionos-0.5.2-local.AppImage` +
> `osionos-desktop_0.5.2-local_amd64.deb`.

## Two ways to run the app
- **`.deb`** (app-menu entry): the installer runs `sudo dpkg -i …` and setuids `chrome-sandbox`
  (needed by Ubuntu 24.04's user-namespace restriction). Launch **osionos** from the menu.
- **AppImage** (single file, no install):
  ```bash
  chmod +x dist-local/osionos-0.5.2-local.AppImage
  ./dist-local/osionos-0.5.2-local.AppImage
  ```
  On **Ubuntu 24.04** the AppImage already runs Chromium with `--no-sandbox` (baked in), but FUSE2
  may be missing — if it won't start, either `sudo apt install libfuse2t64` **or** run
  `./osionos-…AppImage --appimage-extract-and-run`.

## Stop / start the backend
```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml --profile local up -d   # start
docker compose -f docker-compose.yml -f docker-compose.local.yml --profile local down    # stop
```
Data lives in the `track-binocle-postgres-data` volume and survives restarts.

## Notes / limits
- **Architecture:** x86-64 only (build a separate `--arm64` image for ARM).
- **Security:** real local login (gotrue + auth-gateway, JWT + Redis sessions) and Postgres RLS are
  kept. Dropped on purpose for local: TLS-on-loopback, remote/Fly Vault, the distributed data plane.
- **Not yet verified on a clean VM** — test on fresh 22.04 + 24.04 before relying on it (see the
  plan's verification section).
- Heavier/lighter variants (a Docker-less native mode; a hosted multi-machine backend) are planned
  follow-ups.
