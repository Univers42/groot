# Data migration — bring the full stack up on another machine

This is the **authoritative, ordered runbook** for reproducing this machine's complete
state (code + secrets + all-engine data) on a fresh computer, with no rebuild errors.
Written so a human *or* an agent can follow it verbatim.

Three independent payloads carry the state — keep them straight:

| Payload | Where it lives | How it travels |
|---|---|---|
| **Code** | git (monorepo + submodules) | `git clone` + `make syncro-submodule` |
| **Secrets** (`.env*`, `*.secrets`) | **vault42** (zero-knowledge, `vault42.fly.dev`) | `make vault42-pull-all APPLY=1` |
| **Data** (every DB engine + objects) | `apps/grobase/data-snapshots/archives/` (in git) | `restore-databases.sh` |

> **HashiCorp Vault is retired — do not use it.** The only secrets store is **vault42** + the **42ctl** CLI.

---

## 0. Prerequisites on the new machine

- Docker, with the **data-root on a large disk** (`/mnt/storage` here — the system disk is tiny).
- Your **whole vault42 identity dir** copied over: `~/.config/42ctl/` — specifically
  **`keystore.v42`** (the private key) **and `contract-default.tok`** (the tenant contract that
  authorises the vault; the keystore alone gets `Unauthenticated: missing auth metadata`). Easiest is
  `scp -r OLD_HOST:~/.config/42ctl ~/.config/`. Alternatively recover the keystore via
  `make -C apps/grobase ctl-remote ARGS="keys recover --email <you>"` (email-OTP) then `auth login`
  for a fresh contract — but copying the dir is OTP-free. The keystore is unlocked by the passphrase below.
- **vault42 passphrase: `Grobase-Vault-2026!`** (the two common mis-guesses `Osionos-Vault-2026!` /
  `Vault-Osionos-2026!` are **wrong** — they will not unlock the keystore). It is *fake/demo* and
  deliberately shared; rotate it if this ever holds anything real.

---

## 1. Code — clone + synchronize submodules FIRST

A fresh clone leaves submodules **detached at the recorded SHA** (or, worse, on the wrong ref) — the
classic "it built the wrong image" bug. Fix it in one shot:

```bash
git clone <monorepo-url> ft_transcendence && cd ft_transcendence
make syncro-submodule        # forces EVERY submodule onto its stable branch @ latest; never clobbers dirty work
make all                     # only AFTER syncro — rebuilds frontends from the correct source
```

`syncro-submodule` keeps a submodule that is already on a real branch (e.g. `apps/mail` →
`baas-mail-mirror`), and **re-attaches** any detached one to its declared branch (`.gitmodules`,
e.g. `apps/grobase` → `main`) or its remote default; it ff-pulls each to latest and **skips** any
submodule with local changes (so it can't eat uncommitted work). Re-run it anytime sync drifts.

### Caveat — the grobase gitlink (`ffa5a68`)

The data snapshots live in the **grobase** repo. The monorepo records grobase as a gitlink, and that
pointer may lag behind the commit that holds the freshest dumps (`ffa5a68`,
`chore(data-snapshots): refresh dumps to current live data`). `make syncro-submodule` puts
`apps/grobase` on `main@latest` (which **includes** `ffa5a68`), so you get the current archives. If
you instead pin the gitlink, bump it to `ffa5a68` (or newer) first — otherwise `git submodule update`
checks out an older grobase without the latest dumps. Cloning grobase **directly** always has them.

---

## 2. Secrets — pull the `.env*` tree from vault42

```bash
make vault42-pull-all                 # DRY-RUN: shows what would be written
make vault42-pull-all APPLY=1         # actually restore the env tree (FORCE=1 to overwrite existing)
# passphrase prompt (hidden): Grobase-Vault-2026!
```

This restores the whole monorepo env tree (root + grobase + osionos + mail + opposite-osiris +
`tools/seeds/*.env` + realtime), path-aware, decrypted **on your machine**. Project name in the
vault: **`transcendence`**.

> **Agents cannot perform the *push* of secrets** — sending `.env`/`.secrets` to an external endpoint
> is hard-blocked as data-exfiltration regardless of intent. To refresh what's stored, **a human** runs
> `make vault42-push-all` (passphrase hidden). The *pull* (read-back) is fine for anyone.

---

## 3. Data — bring engines up, THEN restore (order matters)

```bash
make -C apps/grobase up                                    # creates the empty DBs/roles + the mini-baas network
CONFIRM=1 apps/grobase/data-snapshots/restore-databases.sh # destructive drop-and-replace into the running engines
docker restart mini-baas-minio mini-baas-realtime          # cache-y services must re-read their volumes
make all                                                   # finally, the root frontends
```

**Why this exact order (skip a step → errors):**
1. **Submodules before build** (step 1) — wrong source ⇒ wrong images.
2. **Secrets before `up`** (step 2) — services read `.env` at boot; missing env ⇒ they crash or run offline.
3. **`grobase up` before restore** — `restore-databases.sh` loads into *running* engines (it skips any that's down) and needs the empty DBs/roles to exist first.
4. **Restore's internal order is already correct** and must not be reshuffled: Postgres **roles/globals → per-DB** (a DB's objects need its roles), then MySQL → MongoDB → MSSQL → DynamoDB → MinIO. Each engine is independent; the script reassembles any split `*.partNN` first.
5. **Restart minio + realtime last** — MinIO caches its bucket tree in memory and won't see freshly-extracted objects until restarted; realtime re-reads after the DBs are populated.

### Caveat — Postgres needs the pgvector image

One table, `osionos_bridge_identities`, has a `vector` (pgvector) column. The grobase Postgres image
(`pgvector/pgvector:pg16`) has the extension, so `make -C apps/grobase up` → restore works end-to-end.
A **stock** `postgres:16` would restore every table *except* that one (missing `CREATE EXTENSION vector`).
Always restore against the grobase stack, never a vanilla postgres.

---

## 4. What IS and IS NOT in the data snapshot (no surprises)

**Captured + restore-verified** (each dump was restored into a fresh throwaway container and counted):

| Engine | Real content verified |
|---|---|
| PostgreSQL (7 DBs + roles) | commerce: 25k orders / 74.8k order-items / 5k customers; +postgres, gourmand, agency, red-tetris, website, realtime |
| MySQL | `ops`: 11,040 rows (tasks 2000, tickets 3000, time_entries 6000); `mini_baas` empty by design |
| MongoDB | `activity`: events 30000, reviews 8000, notes 400 (~38.4k docs) |
| MSSQL | `finance` full backup (data+log, `IsDamaged=0`) |
| DynamoDB | 3 tables, 1,650 items (device_events 1200, alerts 250, devices 200) |
| MinIO | 182 entries, buckets `chat` (53 objects) + `iceberg` |

**Deliberately NOT in the snapshot (and why it's fine):**
- **redis** — cache, regenerates itself.
- **vault42** (its own Postgres DB) — zero-knowledge secrets; travels via 42ctl (§2), never as a dump.
- **grafana / loki / prometheus** — observability (dashboards/logs/metrics), operational not app data.
- **functions-data** — empty (4 KB).

**Stale orphans on *this* machine — correctly not migrated** (no running container mounts them; they're
pre-extraction relics, not live state): `app_mongodb_data` (460 MB old osionos dev Mongo, superseded by
grobase's Mongo), `track-binocle_track-binocle-{postgres,redis,vault}-data` (the old root stack +
the disabled HashiCorp vault). Do **not** ship these.

---

## 5. Network & configuration

- The frontends and grobase talk over the **external Docker network `mini-baas` (real name
  `mini-baas_mini-baas`)** by **container-name DNS** (`mini-baas-kong:8000`, `mini-baas-postgres`,
  `mini-baas-realtime:4000`, …). `make -C apps/grobase up` creates this network; the root `make all`
  only *joins* it (and fails fast if grobase isn't up).
- Restore targets the **live container names** (`mini-baas-postgres`, `-mysql`, `-mongo`, `-mssql`,
  `-dynamodb-local`, `-minio`) — so the grobase stack must be up first with those names (it is, by default).
- Env that wires it together comes back via §2 (`VITE_BAAS_URL`, `JWT_SECRET`, `REALTIME_JWT_SECRET`,
  the bridge service-role key, DSNs, etc.). The grobase `JWT_SECRET` doubles as `REALTIME_JWT_SECRET`.
- Desktop/Electron targets must use **`127.0.0.1`**, not `localhost` (Kong is IPv4-only).

---

## 6. One-glance: the new machine in one command

```bash
# copy the WHOLE ~/.config/42ctl/ dir over first (keystore.v42 + contract-default.tok + config.json):
#   scp -r OLD_HOST:~/.config/42ctl ~/.config/
git clone --recursive <url> ft_transcendence && cd ft_transcendence
make all                # everything, from zero — self-provisions (prompts once for the vault42 passphrase)
```

`make bootstrap` runs the whole sequence below in order — it's the from-zero / wiped-machine command:

```bash
make syncro-submodule                                  # 1. correct source / images
make vault42-pull-all APPLY=1                           # 2. secrets  (pass: Grobase-Vault-2026!)
make -C apps/grobase up                                 # 3a. engines + network
CONFIRM=1 apps/grobase/data-snapshots/restore-databases.sh   # 3b. data (DESTRUCTIVE drop-replace)
docker restart mini-baas-minio mini-baas-realtime       # 3c. cache re-read
make all                                                # 4. frontends
```

Login `dev.pro.photo / Osionos123!`. If something is empty, the engine was down at restore time —
bring it up and re-run `restore-databases.sh` (idempotent drop-and-replace).

> **`make bootstrap` vs `make all`:** `bootstrap` is the **one-time from-zero** command (it includes the
> *destructive* data restore). `make all` is the **everyday** lifecycle (certs → guard backend → frontends
> → health) — on an existing machine the Docker volumes persist, so `make all` already brings everything
> back without touching data. If `make all` errors that the backend is down, it now points you to
> `make bootstrap`.
