# 0050. The inception mounts move to a VM copy on its own internal network

- Status: accepted with conditions (devil, PROCEED-WITH-CONDITIONS IR1–IR15; `showcase` amended
  2026-11-17 under SH1–SH17, `.claude/agent-memory/devil/inception-showcase-verdict.md`)
- Date: 2026-11-16
- Deciders: devil (risk ruling). The VM operator lives with it.

## Context

- Three tenant_owned MySQL mounts of tenant `agency` (5d1bbdb5 showcase, ed58200d lab, 580414fa wordpress)
  point at `dlesieur42-3.tail10f2ea.ts.net:3306`. That tailnet node was last seen 2026-11-04 and cannot be
  powered on. The VM has a 42-Inception MariaDB datadir (`/home/dlesieur/data/mariadb`, 77M, last written
  2026-10-28) with `lab` and `wordpress`. It has no `showcase`.
- `isPlatformHost` returns true for any host name without a dot (`control-plane/internal/adapterregistry/descriptor_dsn.go:127-137`).
  `guardPlatformPatch` refuses a connection_string PATCH when the CURRENT DSN is platform (`patch.go:155`).
  So a repoint to `agency-inception-db:3306` can never be PATCHed back.
- The PATCH response is a `MountDescriptor` with no connection string (`descriptor.go:25-39`). The patch log
  line logs no DSN (`patch.go`, `Patch`). Registry `PACKAGE_ENFORCEMENT=0` and the tenant plan is `free`, so
  `ErrPlaintextDsnForbidden` does not fire (`service.go:142,163`).
- Router `SECURITY_MODE=baseline`. A mysql DSN without `require_ssl` connects in plaintext (`data-plane-pool/src/mysql/tls.rs:17-24`).
  Dial guard is Off.
- `ghcr.io/univers42/grobase-mariadb:latest` ships `ha_connect.so`, `ha_federatedx.so`, `ha_spider.so` and `ha_s3.so`.
  This was listed in the running `mini-baas-mariadb`, which uses the same tag.
- `mini-baas_mini-baas` has 35 members, including `mini-baas-functions`. `FUNCTIONS_NET_ALLOWLIST_ENABLED` is unset,
  so tenant Workers keep `net: "inherit"` (`infra/docker/services/functions-runtime/src/server.ts:92-99`).
- `make down` runs `$(DCE) down` (`orchestrators/makes/20-stack.mk:22-23`). Docker refuses to remove a network
  that still has active endpoints.
- `b2b-backup` dumps only mini-baas-postgres, mysql, mongo and redis, plus docker volumes (`/usr/local/sbin/b2b-backup:29-51,87`).
- Unknown when this was written, measured since (2026-11-16, account step, devil A1–A15):
  - The DSN user did not exist in the copy. lab and wordpress share one user and one password. The copy
    held only the two Inception `@%` accounts plus the localhost ones (`mariadb.sys`, root, the socket login).
  - Each Inception `@%` account holds USAGE globally plus a DB-level grant on one schema. Their passwords
    are school-project passwords of unknown strength.
  - What -3 held after 2026-10-31 is still unknown. The copy is the 2026-10-28 state.
- Measured 2026-11-17 for `showcase` (VM, read-only):
  - Its rows were found nowhere reachable: not in the datadir copy, the host datadir, the platform mysql
    dump, `audit_log`, or any transcript. Binary files, archives, other machines and -3 were not searched.
  - The 8 osionos pages that use the mount read 23 table names. osionos holds 27 object databases
    `db-inception-live-showcase-*` (created 2026-11-01 18:50Z) with column definitions for 20 tables; only
    8 of the 23 names are among them. The object databases have no link to the mount.
  - `audit_log` holds 8,727 successful requests on the mount over 38 table names, 2026-10-31 21:33Z to
    2026-11-04 09:47Z: list 8,449, aggregate 251, get 18, update 9, insert 0. It holds no row data.
  - The showcase DSN has its own user, not the lab/wordpress one, and the copy had no such account.
  - `tenant_databases.last_healthy_at` read 2026-11-16 23:19:57Z while the mount answered 502.
- The registry accepts a mysql mount to any host (`patch.go:28-34`), and the mysql dial guard is Off
  (`data-plane-pool/src/mysql/adapter.rs:53`). Once the router joins the network, any tenant can register a
  mount to the alias and try passwords through the router.

## Decision

- The mounts point at a copy of the datadir, served by a dedicated `agency-inception` compose project. It is
  attached only to its own `internal: true` network. The data-plane router joins that network live, and no
  other platform container joins it.
- The DSN host is a dotted alias under a reserved non-public suffix. That keeps the mounts classified
  `network`, so PATCH rollback stays possible.
- Plugin loading is locked off.
- `showcase` stays on -3 unless the user chooses an empty database.
- Amended 2026-11-17 (IR8 resolved): the user asked for the query-router error to be repaired after the
  empty option was offered. `showcase` points at the copy, at a schema that holds exactly one table,
  `_about_this_copy`, whose single row says it is empty on purpose and is not a restore. No table is
  rebuilt and no row is invented.

## Alternatives considered

- **The plan's `mini-baas_mini-baas` attachment.** Lost on three counts:
  - Tenant Workers could reach the DB, and its only guard is school-project credentials of unknown strength.
  - A DSN user with global privileges could `INSTALL SONAME` CONNECT/FederatedX and pivot into 35 platform containers.
  - A foreign endpoint couples grobase's `make down` and network recreate to this project.
- **A dotless service name.** Lost because it is classified platform, so rollback is refused (`patch.go:155`).
- **Publishing 3306 on the VM tailnet IP.** Lost because it exposes MariaDB to every tailnet device.
- **An empty `showcase` by default.** Lost because it turns a visible failure into silent data loss that
  looks healthy.
- **`showcase` rebuilt as 20 empty tables from the osionos definitions** (devil BLOCK, 2026-11-17). Lost
  because it covers 8 of the 23 tables the pages read, and the covered blocks would show totals of 0 that
  look real (`.out-of-scope/showcase-rebuilt-from-osionos-definitions.md`).

## Consequences

- Conditions IR1–IR15 (devil, 2026-11-16) are the acceptance criteria. Key ones:
  - alias classification and a rollback rehearsal on one mount before the other two;
  - the functions container proven unable to reach the DB;
  - DSN users hold USAGE only globally;
  - in-process secrets with a byte-exact host swap;
  - a disclosure about data lineage and backup.
- Any router recreate drops the live network attachment. The mounts then fail closed, as they do today, until
  the re-attach runs. The VM rollout script owns that re-attach step.
- G2 dial-guard enforce will deny these mounts (172.x is private). The enforce inventory must list them. No
  subnet allowlist (C13 stands). A single-host exception needs its own ruling.
- The copy at `/var/lib/agency-inception-db` is not in restic until it is added. It diverges from -3 with every write.
- The account step (devil A1–A15) is part of this decision:
  - A5: the DSN user is created in the copy, from its own password's native hash. It holds exactly the nine
    privileges the mysql adapter uses (DML plus table DDL) on `lab` and `wordpress`.
  - A7: the two Inception `@%` accounts are locked, never dropped. A remote login works only for the DSN
    user. That closes the router-as-deputy path above.
  - A13: every `lab`/`wordpress` table is CHECKSUMed before the first PATCH. Rollback refuses when a table
    changed since then, unless `FORCE=1`, because the -3 data would silently replace those writes.
  - A14, if -3 comes back: nothing repoints on its own. The user picks the winner from the checksums. The
    loser's DSN account is locked, and the password is rotated on both servers before any PATCH.
- Live 2026-11-16 17:05Z: lab and wordpress point at the copy, after a rollback rehearsal on lab. showcase
  stays on -3.
- The showcase step (devil SH1–SH17) is part of this decision:
  - SH1: what osionos still holds about showcase (27 object databases, 8 pages, 1 workspace database, the
    audited table names) was frozen to a root-only file beside the copy and to its own restic snapshot
    before the first write.
  - SH4–SH7: the showcase DSN's user is a second account, created from its own password's native hash,
    with the A5 privileges on `showcase` only. A7 becomes an exact set: the lab user, plus the showcase
    user while the mount is enrolled. A8 is checked per user. Each user is refused on the other's schemas.
  - SH8: `showcase` has its own CHECKSUM baseline, recorded once.
  - SH10/SH11: `patch showcase rev` sends showcase alone back to -3, locks its account and refuses when
    the copy's `showcase` was written to, unless `FORCE=1`. It does not stop the compose project, so lab
    and wordpress keep answering. The full rollback reverts showcase first.
  - SH13: the router is never recreated for this.
  - SH16: A14 covers showcase. If -3 returns, the user picks the winner, the loser's showcase account is
    locked, and the showcase password is rotated on both servers before any PATCH.
- Live 2026-11-17 00:05Z: showcase points at the copy after one fwd → rev → fwd rehearsal. The schema
  request answers 200 with `_about_this_copy` only. Ten minutes later 0 of the 35 frozen osionos rows had
  changed.
- The 8 pages still show no data. Each block now says its table was not found, where it said 502 before.
  A read of a missing table on a mysql mount still answers 502 at the router, on every mysql mount.
- After a PATCH the router keeps the previous pool for a time: the revert took effect between 2 s and
  2 min 38 s later. The bridge caches an empty schema answer for under about 25 s. A reading taken
  sooner than three minutes after a PATCH proves nothing.
- Writes to the copy's `showcase` are not backed up (IR10 unchanged).
