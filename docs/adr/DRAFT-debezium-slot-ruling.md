# DRAFT. Debezium outbox CDC is retired on live: the stalled slot is dropped and slot WAL is capped at 8 GB

- Status: proposed (draft, unnumbered). devil 2026-11-22: (e) retire + slot drop PwC DZ1–DZ8; (c) cap PwC DZ9–DZ13; (e2) publication drop PwC DZ14–DZ15; (h) repo opt-in profile PwC DZ16; heartbeat (a)/(b), sink unstick (f), narrowed publication (g) BLOCK.
- Date: 2026-11-22
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-debezium-slot.md`

## Context

- The slot `mini_baas_outbox_slot` has not moved: confirmed_flush_lsn is 0/87E62D0 with 1523 MB WAL retained, `max_slot_wal_keep_size=-1`, `archive_mode=off` (read-only SQL, 2026-11-22 20:14–20:17Z).
- Debezium Server 3.0.0.Final logs `Sink memory threshold percentage was reached … estimated 184.23 MB, maxmemory 128.00 MB. Total Processed Records: 0` every second, while Redis `used_memory` is 2.29 MB. Upstream `RedisMemoryThreshold.checkMemory` adds `record size × buffer.fill.rate` (default 30000) to the estimate, so with `memory.limit.mb=128` a record over ~4.2 KB never passes (`infra/docker/services/debezium/application.properties:3`).
- No offset was ever committed: `/tmp/debezium-offsets.dat` is absent in a container created 2026-11-06.
- Nothing reads `mini_baas.public.outbox_events` (the key is absent). The live consumers SCAN `outbox.*` (`src/control-plane/internal/functriggers/dispatcher_streams.go:25`). Those streams are written by the Go relay polling Postgres (`internal/orchestrator/outboxrelay/publish.go:53-54`), and all 7815 outbox rows are `published`.
- The publication is FOR ALL TABLES (275 tables, including auth secrets). Two published tables have no replica identity, so UPDATE/DELETE on them errors.
- Unknown when this was written: the slot's creation date (growth bound ≤380 MB/day) and why no outbox rows were written after 2026-11-16 19:33Z.

## Decision

On live, Debezium is stopped and its slot is dropped. `max_slot_wal_keep_size` is 8 GB, set with ALTER SYSTEM and a reload. The FOR ALL TABLES publication may be dropped as a separate step. In grobase, Debezium moves to an opt-in profile so `make up PACKAGE=max` stops reviving it.

## Alternatives considered

- **heartbeat.interval.ms (with or without an action query and heartbeat table):** has no effect. Heartbeats go through the same `handleBatch`, which is stuck retrying, so no offset commit or LSN flush ever happens. The action-query variant adds live DDL and a second Redis stream that is never trimmed.
- **Raise the sink memory limit:** writes an untrimmed stream (3.0.0 JedisClient XADD has no MAXLEN) that nobody consumes into the shared `volatile-lru` Redis (maxmemory 384 MB), where keys without a TTL cannot be evicted. The cost is a platform-wide Redis OOM instead of a disk that takes ≥170 days to fill.
- **Narrow the publication and keep Debezium:** there is no consumer (rung 0).
- **Cap only:** bounds the disk, but leaves a dead JVM decoding every table, plus a slot that invalidates itself into a restart loop.

## Consequences

- DZ1 re-verify the state no more than 10 min before acting. DZ2 run `docker stop` first, then drop the slot only `WHERE NOT active`. DZ3 never `make up`; the nightly var-gc prunes the stopped container. DZ4 success = 0 slots and waldir ≤ 1088 MB after two checkpoints. DZ5/DZ6 rollback = start or compose-recreate the single service (it recreates the slot at the current LSN). DZ7 the next `make up PACKAGE=max` revives it until (h) lands. DZ8 report it as "CDC retired", not "outbox fixed".
- DZ9–DZ13 cap at 8 GB, which must be greater than the retention at apply time. A slot that is lost goes into a restart loop, and no outbox events are lost. Rollback = ALTER SYSTEM RESET plus a reload.
- DZ14–DZ15 dropping the publication is optional and comes after DZ4. Rollback = `CREATE PUBLICATION mini_baas_outbox_pub FOR ALL TABLES`.
- DZ16 grobase opt-in `cdc` profile, plus fixes to the m8/m66/m211/ci references, in its own change. DZ17 preconditions for any revival with a consumer.
- Supersedes SA7 of the sudo-audit ruling: a slot that has never advanced cannot be required to advance.
