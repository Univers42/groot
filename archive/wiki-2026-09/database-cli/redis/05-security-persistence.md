# Security and Persistence

Redis security is layered: network exposure, authentication, ACL least privilege, and disabling
dangerous commands. Persistence determines what survives a restart: RDB snapshots give compact
point-in-time backups; AOF logs every write for finer-grained recovery. The live container runs
with both enabled.

---

## Security

### Verified config on this container

```bash
docker exec mini-baas-redis redis-cli CONFIG GET protected-mode
# protected-mode: no
# (Docker internal network — not needed)

docker exec mini-baas-redis redis-cli CONFIG GET bind
# bind: * -::*
# (listens on all IPv4; -::* disables IPv6)

docker exec mini-baas-redis redis-cli CONFIG GET requirepass
# requirepass: (empty string)
# No password — dev-only; safe because container is on the mini-baas Docker network

docker exec mini-baas-redis redis-cli ACL WHOAMI
# "default"
```

### protected-mode

When `protected-mode yes` is set and Redis is not bound to `127.0.0.1` and has no password,
Redis refuses remote connections. The live container disables it (`no`) because the Docker
network already isolates the service and the Go/Rust clients connect from within that network.
In production on a host exposed to the internet, set `protected-mode yes` or bind to `127.0.0.1`
only.

### Binding

```text
# redis.conf (pattern — unverified in this container, no config file mounted)
bind 127.0.0.1
```

Binding to `127.0.0.1` prevents all external access at the network layer — the strongest
isolation for a local service. In Docker the equivalent is not exposing the port on the host
(no `ports:` in compose, or `127.0.0.1:6379:6379` if binding is needed).

### ACL least privilege

The best hardening is limiting what each client can do. Patterns from [04-acl-users.md](04-acl-users.md):

```bash
# Create a write-only producer (can only XADD to stream keys)
docker exec mini-baas-redis redis-cli ACL SETUSER stream-producer \
  on ">prodpass!" "~realtime:*" "+XADD" "+PING"

# Create a read-only cache client
docker exec mini-baas-redis redis-cli ACL SETUSER cache-reader \
  on ">cachepass!" "~cache:*" "+GET" "+MGET" "+TTL" "+EXISTS" "+PING"

# Lock down the default user to nothing (then set up named users for each service)
# pattern (unverified here — would break the dev setup):
# ACL SETUSER default off
```

### Disabling dangerous commands — rename-command

`rename-command` in `redis.conf` renames (or disables) commands. This is a config-file-only
option — it cannot be set via `CONFIG SET` at runtime.

```text
# redis.conf — pattern (unverified here, no config file mounted in this container)
rename-command FLUSHALL ""          # disable FLUSHALL entirely
rename-command FLUSHDB  ""          # disable FLUSHDB
rename-command CONFIG   "CFG_ADMIN" # rename to an obscure name
rename-command DEBUG    ""          # disable DEBUG (can crash server)
```

After renaming to `""`, the command does not exist and returns `ERR unknown command`. This is a
defense-in-depth measure alongside ACL — ACL blocks commands per user, `rename-command` removes
them globally.

### TLS note (pattern — unverified here)

Redis 6+ supports TLS for client connections. Configuration is in `redis.conf`:

```text
tls-port 6380
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file  /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
```

The live container does not expose a TLS port (`tls-port` is 0). TLS is not needed inside a
trusted Docker network; it matters when Redis is accessed across an untrusted network boundary.

---

## Persistence

The live container runs with **both** RDB and AOF enabled — the recommended production setup.

### Verified persistence state

```bash
docker exec mini-baas-redis redis-cli INFO persistence
```

```text
rdb_changes_since_last_save: 2
rdb_bgsave_in_progress:      0
rdb_last_bgsave_status:      ok
rdb_saves:                   78
aof_enabled:                 1
aof_last_bgrewrite_status:   ok
aof_current_size:            328231   ← ~320 KB
aof_rewrites:                1
```

```bash
docker exec mini-baas-redis redis-cli CONFIG GET save
# save: 3600 1 300 100 60 10000
# Meaning: save if (1 change in 3600s) OR (100 changes in 300s) OR (10000 changes in 60s)

docker exec mini-baas-redis redis-cli CONFIG GET appendonly
# appendonly: yes

docker exec mini-baas-redis redis-cli CONFIG GET appendfsync
# appendfsync: everysec

docker exec mini-baas-redis redis-cli CONFIG GET aof-use-rdb-preamble
# aof-use-rdb-preamble: yes
```

---

### RDB — point-in-time snapshots

RDB writes a compact binary dump of the dataset to `dump.rdb`. It is fast to load on startup.

```bash
# Trigger a foreground save (blocks until done — avoid on busy servers)
docker exec mini-baas-redis redis-cli SAVE
# OK

# Background save (non-blocking, runs in forked process)
docker exec mini-baas-redis redis-cli BGSAVE
# Background saving started

# Check when the last successful save completed (Unix timestamp)
docker exec mini-baas-redis redis-cli LASTSAVE
# (integer) 1782642356
```

**Tradeoffs:**
- Compact and fast to restore.
- Data written since the last snapshot is lost on crash.
- `BGSAVE` uses `fork()` — a brief copy-on-write pause; can be expensive on large datasets.

---

### AOF — append-only file

AOF logs every write command. On restart Redis replays the log to reconstruct state. More
durable than RDB at the cost of larger files.

```bash
# Trigger a background AOF rewrite (compacts the log)
docker exec mini-baas-redis redis-cli BGREWRITEAOF
# Background append only file rewriting started
```

**`appendfsync` options:**

| Value | Durability | Performance |
|-------|-----------|-------------|
| `always` | Every write persisted (strongest) | Slowest |
| `everysec` | At most 1 second of data loss | Good balance (live setting) |
| `no` | OS decides when to flush | Fastest, weakest |

**`aof-use-rdb-preamble yes`**: on AOF rewrite, Redis writes an RDB preamble followed by AOF
commands. This makes reloads faster (RDB loads quickly; only new commands need replay).

---

### maxmemory and eviction

```bash
docker exec mini-baas-redis redis-cli CONFIG GET maxmemory
# maxmemory: 402653184   ← 384 MB

docker exec mini-baas-redis redis-cli CONFIG GET maxmemory-policy
# maxmemory-policy: volatile-lru
```

When memory fills up, Redis applies the eviction policy:

| Policy | Behavior |
|--------|---------|
| `noeviction` | Returns error on write; data safe but writes fail |
| `volatile-lru` | Evicts least-recently-used keys **with a TTL** (live setting) |
| `allkeys-lru` | Evicts LRU from **all** keys regardless of TTL |
| `volatile-ttl` | Evicts keys with shortest TTL first |
| `allkeys-random` | Random eviction from all keys |
| `volatile-random` | Random eviction from keys with TTL |

`volatile-lru` is sensible for this stack: cache keys (with TTL) can be evicted, while
persistent data (no TTL) is protected.

To change at runtime:

```bash
# pattern (unverified here — auto-mode denied CONFIG SET during verification)
# docker exec mini-baas-redis redis-cli CONFIG SET maxmemory-policy allkeys-lru
```

---

### Durability tradeoffs summary

| Setup | Data loss on crash | Restart time |
|-------|-------------------|-------------|
| No persistence | All data lost | Instant (empty) |
| RDB only | Since last snapshot | Fast |
| AOF everysec | Up to 1 second | Moderate (replay) |
| AOF always | None | Slowest |
| RDB + AOF (live) | Up to 1 second | Fast (RDB preamble) |

The live container uses **RDB + AOF with `everysec`** — the standard production-balanced
configuration.

---

## Gotchas / Docker notes

- **No config file in this container**: `redis-cli CONFIG GET config_file` returns empty. Changes
  made with `CONFIG SET` are in-memory and lost on container restart. For permanent changes, build
  a custom image with a `redis.conf`, or mount one via the compose file.
- **`CONFIG SET` blocked in this guide**: `CONFIG SET maxmemory` modifies global server state
  shared with production data in db 0. Treat `CONFIG SET` as a privileged operation; verify
  changes with `CONFIG GET` first.
- **`SAVE` blocks**: use `BGSAVE` in any environment with live traffic. `SAVE` halts the event
  loop until the dump is complete.
- **`rename-command` is config-file only**: it cannot be applied at runtime via `CONFIG SET`.
  A container restart with a mounted `redis.conf` is required.
- **AOF + RDB preamble**: with `aof-use-rdb-preamble yes`, the AOF file is not human-readable
  at the top (it starts with the RDB binary blob). Only the commands appended after the rewrite
  are in text form.

---

Previous: [04-acl-users.md](04-acl-users.md) | [README](README.md)
