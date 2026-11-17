# 0050. The inception mounts move to a VM copy on its own internal network

- Status: accepted with conditions (devil, PROCEED-WITH-CONDITIONS IR1–IR15)
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

## Alternatives considered

- **The plan's `mini-baas_mini-baas` attachment.** Lost on three counts:
  - Tenant Workers could reach the DB, and its only guard is school-project credentials of unknown strength.
  - A DSN user with global privileges could `INSTALL SONAME` CONNECT/FederatedX and pivot into 35 platform containers.
  - A foreign endpoint couples grobase's `make down` and network recreate to this project.
- **A dotless service name.** Lost because it is classified platform, so rollback is refused (`patch.go:155`).
- **Publishing 3306 on the VM tailnet IP.** Lost because it exposes MariaDB to every tailnet device.
- **An empty `showcase` by default.** Lost because it turns a visible failure into silent data loss that
  looks healthy.

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
