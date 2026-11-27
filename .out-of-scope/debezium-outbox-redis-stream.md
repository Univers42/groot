# Repairing Debezium's outbox → Redis stream is out of scope

- Decided: 2026-11-22 · by devil (ruling `/mnt/storage/dlesieur/scratch/me-d/RULING-debezium-slot.md`)
- Holds while: nothing consumes `mini_baas.public.outbox_events` and the Go outbox relay delivers `outbox.*`

## The concept

Make the Debezium Server (Redis sink) CDC pipeline work. The proposals were to add `heartbeat.interval.ms` with or without a heartbeat table, or to raise `memory.limit.mb` / `buffer.fill.rate`, so the logical slot advances and outbox changes reach Redis.

## Why not

- Nothing reads the stream. Consumers SCAN `outbox.*` (`apps/grobase/src/control-plane/internal/functriggers/dispatcher_streams.go:25`, `internal/webhooks/consume.go:10-13`). The Go relay polls Postgres and writes those streams (`internal/orchestrator/outboxrelay/publish.go:53-54`). The live key `mini_baas.public.outbox_events` does not exist.
- A working sink writes with XADD and no MAXLEN (3.0.0 JedisClient) into a shared `volatile-lru` Redis whose maxmemory is 384 MB. Keys without a TTL cannot be evicted, so the stream grows until every service hits OOM.
- What would have to change: a real consumer of Debezium's stream appears, for example log-based delivery replacing the polling relay. Then the DZ17 preconditions apply: offsets on a volume or in Redis, an explicit `snapshot.mode`, a trim owner, consumer dedupe on `id`/`idempotency_key`, and a new ruling.

## Prior requests

- 2026-11-22 (ME-D lane): heartbeat fix for the stalled `mini_baas_outbox_slot`. Refused: the sink had processed 0 records since it started.

## Reopen when

A consumer of Debezium's Redis stream exists in code, or the polling relay is being retired.
