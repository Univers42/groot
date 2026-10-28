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
  `make -C apps/grobase ctl42 ARGS="keys recover --email <you>"` (email-OTP) then `auth login`
  for a fresh contract — but copying the dir is OTP-free. The keystore is unlocked by the passphrase below.
- **vault42 passphrase:** the vault owner gives it to you out-of-band. It is never written in
  this repo (the repo is public).

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
# passphrase prompt (hidden): the vault42 passphrase from the vault owner
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
make vault42-pull-all APPLY=1                           # 2. secrets  (prompts for the vault42 passphrase)
make -C apps/grobase up                                 # 3a. engines + network
CONFIRM=1 apps/grobase/data-snapshots/restore-databases.sh   # 3b. data (DESTRUCTIVE drop-replace)
docker restart mini-baas-minio mini-baas-realtime       # 3c. cache re-read
make all                                                # 4. frontends
```

Login `dev.pro.photo@gmail.com`, password from `make demo-login` (minted per machine). If something is empty, the engine was down at restore time —
bring it up and re-run `restore-databases.sh` (idempotent drop-and-replace).

> **`make bootstrap` vs `make all`:** `bootstrap` is the **one-time from-zero** command (it includes the
> *destructive* data restore). `make all` is the **everyday** lifecycle (certs → guard backend → frontends
> → health) — on an existing machine the Docker volumes persist, so `make all` already brings everything
> back without touching data. If `make all` errors that the backend is down, it now points you to
> `make bootstrap`.

## 7. 2026-10-11 — the b2b data center and this machine's older database

The b2b data center (`wiki/runbooks/grobase-link.md`) was seeded from the vault snapshot of
2026-09-19. This machine's volume `mini-baas_postgres-data` (last shut down 2026-09-27) is a
sibling lineage, not an ancestor: a key-by-key diff found rows only it held. They were merged into
the data center on 2026-10-11, insert-only plus newest-wins on `updated_at`. The merge was
rehearsed on a physical clone with a byte-identical undo, and a `devil` verdict was reached
before it touched live data:

| | rows |
|---|---|
| inserted | 258 — 56 osionos pages of `dev.pro.photo@gmail.com` (Dev Hub, Sprint Board, Architecture Notes, Deploy Runbook, Daily Notes, portfolio, club and course pages), 55 object databases, 53 page configurations, 51 bridge audit events, comments, favorites, reactions, notifications, one workspace and its member; tasks and page links rebuilt by the page triggers |
| refreshed (old copy newer) | 15 — 10 page configurations, a page, a workspace, a member, a bridge identity, a user's `last_sign_in_at` |
| left out on purpose | 19 e2e accounts (`@example.com`/`.org`) and every row naming them (217 ids); auth sessions, refresh tokens, MFA claims, audit log; `auth.osionos_pages_header_backup_20260713` (a July backup table); one object database that the data center already holds, newer, under another id |
| not merged | `commerce.edges` (+998 rows): generated playground data from a different loader run; vault42: travels by 42ctl (§4) |

After the merge, every row only the old database holds is in the left-out set. That was checked
key by key. Undo is a ledger: schema `merge_20261011` on the data center (`ledger` holds the
inserted and updated keys, `replaced` holds the overwritten rows). `merge-old-local.sh live --undo`
reverses it, but only while nobody has edited the restored pages: the foreign keys cascade.
Everything sits in `/var/lib/grobase-import/merge-20261011/` on the VM, with sha256s:
- the pre-merge dump of the live database;
- dumps of the old `postgres` and `commerce` databases;
- the script, the ledger and the replaced rows.

The volume itself is untouched; keep it until you have looked at the restored pages.

The other engines were counted against this machine's volumes the same day. None needed a merge;
two needed loading:

| engine | data center | this machine |
|---|---|---|
| MySQL `ops` | projects 40, tasks 2000, tickets 3000, time entries 6000 (the 11,040 of §4) | same |
| Mongo | activity events 30000, product reviews 8000, notes 400 | same |
| MSSQL `finance` | cost centers 12, GL accounts 20, invoices 600, invoice lines 603, payments 400 | same (counted on a throwaway copy of `mini-baas_mssql-data`) |
| DynamoDB | was **empty**: the 2026-09-19 `secrets/MANIFEST.json` lists `dynamodb` as skipped, so `make import-pack` left it out of the import. Loaded on 2026-10-11 from the older `secrets/dynamodb-all.tar.gz` (captured 2026-09-17): alerts 250, device events 1200, devices 200 | no volume; that seed is the only copy |
| MinIO `chat` | 54 objects | 57: the 4 extra belong to excluded e2e accounts (one fixture PNG uploaded by three of them); 1 object is newer on the data center |
| SQLite `osionos-restaurant` | was empty (`no such table`); **regenerated**, not restored, by `seed_sqlite` of `scripts/seed/osionos-extra-engines.sh`: 1045 rows | `secrets/sqlite-data.tar.gz` holds an empty 4 KB file |
| MariaDB, CockroachDB | no user tables | no volume |

Whiteboard boards live in grobase Mongo (`hydrawn_boards`, `hydrawn_thumbnails`, owner-scoped through the osionos bridge). Boards of the retired drawnosaurus service were local-only and were not migrated.

Until 2026-10-11 the data center's data plane did not serve DynamoDB at all. It now does: the four
`.env` values grobase documents for it, and the `:latest-dynamodb` router image. The `.env` before
that change is `/opt/grobase/.env.bak-dynamo-20261011T180948Z` on the VM. The next `vault-seed.sh`
run with `dynamodb-local` up captures DynamoDB again, so a fresh import carries it.

## 8. 2026-10-12 — the June track-binocle database

The older `track-binocle` volume (a dump of 2026-06-12) held accounts the data center never had,
among them `dylan@gmail.com`. 258 of that account's 280 June pages were already in the data center
under `dev.pro.photo@gmail.com`. The rest was merged on 2026-10-12 at 17:17 UTC with §7's tool and
rules: insert only, e2e accounts left out, and a user whose email the data center already holds
under another id left out. The tool now takes `MERGE_SCHEMA`, so this run's ledger is
`merge_20261012` and §7's ledger stays untouched.

| table | inserted |
|---|---|
| `auth.users`, `auth.identities` | 18 each |
| `public.osionos_pages` | 44 |
| `public.osionos_page_configurations` | 35 |
| `public.osionos_workspace_members` | 25 |
| `public.osionos_page_action_events` | 22 |
| `public.osionos_bridge_identities` | 16 |
| `public.osionos_workspaces` | 14 |
| `public.osionos_bridge_audit_events` | 82 |

Nothing was overwritten (`merge_20261012.replaced` is empty). The merged accounts keep their June
password hashes. `dylan@gmail.com`'s June password is in this public repository's history, and the
Funnel serves sign-in to the internet, so change it once its pages are where you want them.

Undo: `MERGE_SCHEMA=merge_20261012 merge-old-local.sh live --undo`. As in §7, it works only while
nobody has edited the merged pages. The pre-merge dump, the June dump, the script, the ledger and
the dry-run and commit outputs are in `/var/lib/grobase-import/merge-20261012/` on the VM, with
sha256s.

`higueraslp@gmail.com` came from neither source with a password anyone knew (`dev.pro.photo`'s
and `dylan@gmail.com`'s known values both failed against its hash). On 2026-10-12 its password
was replaced through `grobase users update --password-stdin` with the service-role key, so the
owner can sign in to that account. The replaced hash is in `merge_20261012.password_resets` on
the data center; writing it back into `auth.users.encrypted_password` restores the old password.

## 9. 2026-10-12 — every mount checked through grobase-cli

The agency tenant's seven mounts were read back through `grobase` (grobase-cli 112a848), with
the osionos app's own API key, so the check is what the app sees. Nothing needed loading:

| mount | engine | through the tailnet (rows, paged 500 at a time) |
|---|---|---|
| mysql-ops | mysql | projects 40, tasks 2000, tickets 3000, time_entries 6000 — all equal to §7 |
| osionos-finance | mssql | cost_centers 12, gl_accounts 20, invoices 600, invoice_lines 603, payments 400 — all equal to §7 |
| mongo-activity | mongodb | events 30000, product_reviews 8000, notes 400 — all equal to §7 |
| osionos-iot | dynamodb | alerts 250, device_events 1200, devices 200 — all equal to §7 |
| osionos-restaurant | sqlite | restaurant 8, menu 8, dish 65, working_hours 56, restaurant_order 300, order_item 608 |
| pg-commerce | postgresql | customers 5000, products 1200, orders 25000, order_items 74822, employees 60, inventory 2644, edges 6544 |
| agency-db | postgresql | cases 40, subjects 60, transactions 150 (12 tables in all) |

Through the Funnel, from a container that resolves the name in public DNS, every one of those
31 tables returned a row. `grobase db test` lists each mount's resources. `grobase db migrate`
applied `20261012_grobase_cli_check` (`SELECT 1;`) to mysql-ops, pg-commerce and agency-db,
and a second run reported it `skipped`. That file's row in each mount's `_baas_migrations` is
the only thing the check wrote. mongo-activity refuses migrations with a 422 (no `ddl`
capability), as documented.

Raw SQL (`grobase query run`) does not reach these mounts, and that is by design. grobase's SQL
runner serves only `tenant_owned` postgres mounts, with `QUERY_ROUTER_SQL_RO` on. Both postgres
mounts here are `shared_rls`, where raw SQL would bypass row ownership. Count through
`query crud`/`api` instead.

## 10. 2026-10-13 — legacy workspace permissions

Rows copied as they were carry their era's vocabulary. Thirteen `osionos_workspace_members`
rows from June 2026 held `{read,write}`, and the bridge grants nothing for `write`, so an
editor of Binocle Intelligence Agency or Acme Operations got "addPage: create failed —
Workspace permission denied." on every device. One of those rows came with §8's merge.
`models/osionos-workspace-permissions-migration.sql` maps `write` to create, update and
delete. `models-migrate` applies it to every grobase, and it was applied to the data center
on 2026-10-13. The old values are in `fix_20261013.workspace_member_permissions`, whose table
comment holds the one-statement undo.

A merge that copies rows from an older database should run `models-migrate` afterwards.
