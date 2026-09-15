# Connecting to Redis via Docker

`redis-cli` has two modes: an **interactive REPL** and a **one-shot** command runner. Both are
reached through `docker exec` because there is no host-installed Redis client — the binary lives
only inside `mini-baas-redis`.

## Interactive vs one-shot

```bash
# Interactive — drops you into a REPL; type commands and press Enter
docker exec -it mini-baas-redis redis-cli

# One-shot — runs a single command, prints result, exits
docker exec mini-baas-redis redis-cli PING
```

Expected output for `PING`:

```text
PONG
```

The `-it` flags allocate a pseudo-TTY and keep stdin open. Drop them for one-shot commands or
piped input.

## Logical databases and the `-n` flag

Redis ships 16 logical databases (0–15) in a single process. They share RAM and config but have
separate keyspaces. The `-n <db>` flag selects the database at connection time.

```bash
# Connect to scratch db 15
docker exec -it mini-baas-redis redis-cli -n 15

# Inside interactive mode, switch database with SELECT
127.0.0.1:6379[15]> SELECT 0
OK
127.0.0.1:6379> SELECT 15
OK
```

The `[15]` in the prompt confirms which database is active.

> **Convention:** all exercises in this guide use `-n 15` and `learn:` key prefix. Never use
> db 0 for practice — it holds live production data.

## PING — the liveness check

```bash
docker exec mini-baas-redis redis-cli -n 15 PING
# PONG

docker exec mini-baas-redis redis-cli -n 15 PING "hello"
# hello
```

## INFO — server metadata

```bash
# Full info report
docker exec mini-baas-redis redis-cli INFO

# A specific section (server, clients, memory, persistence, stats, keyspace…)
docker exec mini-baas-redis redis-cli INFO server
docker exec mini-baas-redis redis-cli INFO keyspace
```

```text
# Keyspace (example from live container)
db0:keys=2529,expires=2492,avg_ttl=41098731
db15:keys=0,expires=0,avg_ttl=0
```

## DBSIZE — key count in current db

```bash
docker exec mini-baas-redis redis-cli -n 15 DBSIZE
# (integer) 0
```

## CLIENT LIST — active connections

```bash
docker exec mini-baas-redis redis-cli CLIENT LIST
```

```text
id=6 addr=172.19.0.17:53428 ... cmd=xreadgroup user=default lib-name=go-redis ...
id=7 addr=172.19.0.17:53422 ... cmd=xreadgroup user=default lib-name=go-redis ...
```

The live container shows the Rust/Go realtime plane holding persistent `XREADGROUP` connections
on db 0. CLIENT LIST is safe to run anytime — it is read-only.

## MONITOR — real-time command log

```bash
docker exec -it mini-baas-redis redis-cli MONITOR
```

`MONITOR` streams every command sent to the server in real time. It has **measurable overhead**
(can halve throughput under load) and exposes all client commands including data values. Use it
only for short debugging sessions on dev, never in production.

Press `Ctrl-C` to stop.

## --scan — safe key iteration

```bash
# List all keys in db 15 matching a pattern (non-blocking, cursor-based)
docker exec mini-baas-redis redis-cli -n 15 --scan --pattern "learn:*"
```

```text
learn:hello
learn:counter
learn:queue
...
```

`--scan` iterates using the `SCAN` command internally, which is safe under load. It is the
recommended alternative to `KEYS *` for listing keys. See [02-keys-ttl.md](02-keys-ttl.md) for
why `KEYS` blocks in production.

## Running a command file via pipe

Send a batch of commands to Redis by piping them through stdin:

```bash
printf "SET learn:a 1\nSET learn:b 2\nMGET learn:a learn:b\n" \
  | docker exec -i mini-baas-redis redis-cli -n 15
```

```text
OK
OK
1
2
```

Note `-i` (not `-it`) — pipe mode needs stdin connected but not a TTY. This is useful for
seeding test fixtures or running migration scripts without entering the interactive shell.

## Raw vs human-readable output

By default `redis-cli` formats output for human reading (adds type labels, quotes). Pass
`--no-raw` to force plain output (useful when piping to other tools):

```text
# Default (human)
127.0.0.1:6379[15]> GET learn:hello
"world"

# --no-raw
$ docker exec mini-baas-redis redis-cli -n 15 --no-raw GET learn:hello
"world"
```

For truly raw bytes (no quoting), use `--raw`.

## Scratch-db cleanup

```bash
# Clean up only db 15 — surgical and safe
docker exec mini-baas-redis redis-cli -n 15 FLUSHDB

# Confirm it is empty
docker exec mini-baas-redis redis-cli -n 15 DBSIZE
# (integer) 0

# NEVER run — destroys all databases
# docker exec mini-baas-redis redis-cli FLUSHALL
```

## Gotchas / Docker notes

- **`-it` vs `-i`**: always use `-it` for interactive sessions so the REPL can detect terminal
  width. Use `-i` (no `-t`) when piping commands from the host — a TTY is not available there.
- **No host binary**: `redis-cli` only exists inside the container. Any alias like
  `alias redis-cli='docker exec -it mini-baas-redis redis-cli'` makes iteration faster.
- **`MONITOR` overhead**: a single `MONITOR` subscriber can cut server throughput in half. Keep
  sessions short.
- **db 0 is live**: the container has ~2 500 keys in db 0 with active `XREADGROUP` consumers
  (the grobase realtime engine). Never run `FLUSHDB` without `-n 15`.

---

Next: [01-data-types-crud.md](01-data-types-crud.md) | [README](README.md)
