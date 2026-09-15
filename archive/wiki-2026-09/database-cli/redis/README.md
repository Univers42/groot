# Redis — Docker CLI Learning Notes

Redis 7.2.11 runs inside `mini-baas-redis` as an **in-memory data-structure store**: every value
is a typed object (String, Hash, List, Set, Sorted Set, Stream…), not a row. Think in data
structures, not tables.

## Verified version

```text
redis_version: 7.2.11
tcp_port:      6379
maxmemory:     384 MB  (volatile-lru eviction policy)
AOF:           enabled
RDB:           enabled  (60 10000 / 300 100 / 3600 1)
```

## Connect one-liners

```bash
# Interactive shell (default db 0 — production data)
docker exec -it mini-baas-redis redis-cli

# Scratch db — always use this for learning
docker exec -it mini-baas-redis redis-cli -n 15

# One-shot (non-interactive)
docker exec mini-baas-redis redis-cli -n 15 PING
```

No password is configured (`requirepass` is empty), so `AUTH` is not required to connect as
`default`. See [04-acl-users.md](04-acl-users.md) for how to add one.

## Safety convention: db 15 + `learn:` prefix

All exercises in this guide use **logical database 15** (`-n 15`) and prefix every key with
`learn:`. This keeps practice keys completely separate from the production data in db 0.

To clean up at any time:

```bash
# Wipe only db 15 — safe, surgical
docker exec mini-baas-redis redis-cli -n 15 FLUSHDB

# NEVER run this — it nukes every database including production
# FLUSHALL   ← DO NOT USE
```

## Files in this series

| File | Topic |
|------|-------|
| [00-connect.md](00-connect.md) | `redis-cli` modes, `PING`, `INFO`, `DBSIZE`, `MONITOR`, `--scan`, pipes |
| [01-data-types-crud.md](01-data-types-crud.md) | Strings, Hashes, Lists, Sets, Sorted Sets — CRUD with scenarios |
| [02-keys-ttl.md](02-keys-ttl.md) | `EXISTS`, `TYPE`, `SCAN` vs `KEYS`, expiry, `OBJECT ENCODING`, namespacing |
| [03-pubsub-streams.md](03-pubsub-streams.md) | Pub/Sub and Streams — fire-and-forget vs durable log |
| [04-acl-users.md](04-acl-users.md) | ACL system, users, passwords, `AUTH`, least privilege |
| [05-security-persistence.md](05-security-persistence.md) | Security config, RDB/AOF persistence, eviction, `CONFIG GET/SET` |
