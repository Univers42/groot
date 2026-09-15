# Pub/Sub and Streams

Redis provides two message-passing models. **Pub/Sub** is a fire-and-forget broadcast: publishers
send messages to channels and any subscribed clients receive them instantly — but if no one is
listening, the message is gone. **Streams** are an append-only durable log (like a lightweight
Kafka topic): messages persist until explicitly trimmed, and consumer groups track which messages
have been processed.

The live container (`mini-baas-redis`) uses Streams heavily — the grobase realtime engine keeps
persistent `XREADGROUP` connections on db 0 (visible in `CLIENT LIST` output).

---

## Pub/Sub

### How it works

- A subscriber blocks, waiting for messages on named channels.
- A publisher sends a message to a channel — all current subscribers on that channel receive it.
- If there are no subscribers, the message is discarded.
- Pub/Sub operates outside the key-value space: no keys are created, no TTL applies.

### Scenario — two docker exec shells

**Shell 1 — subscriber:**

```bash
docker exec -it mini-baas-redis redis-cli
```

```text
SUBSCRIBE learn:notifications
# Reading messages... (press Ctrl-C to quit)
# 1) "subscribe"
# 2) "learn:notifications"
# 3) (integer) 1
```

The client is now blocked in subscribe mode.

**Shell 2 — publisher (open a new terminal):**

```bash
docker exec -it mini-baas-redis redis-cli PUBLISH learn:notifications "deploy complete"
# (integer) 1   ← number of subscribers that received the message
```

**Back in Shell 1 you see:**

```text
1) "message"
2) "learn:notifications"
3) "deploy complete"
```

### Pattern subscribe

```text
# Subscribe to all channels matching a glob
PSUBSCRIBE learn:*

# Unsubscribe from pattern
PUNSUBSCRIBE learn:*
```

### Cleanup

Pub/Sub leaves no keys. Just press `Ctrl-C` in the subscriber shell.

---

## Streams

A Stream is a sequence of entries, each identified by an auto-generated `timestamp-sequence` ID.
Entries contain field-value pairs (like a Hash). Unlike Pub/Sub, entries persist and can be
consumed by multiple independent consumer groups at different offsets.

### XADD — append an entry

```bash
docker exec mini-baas-redis redis-cli -n 15 \
  XADD learn:events '*' user alice action login ip 192.168.1.1
# 1782642545394-0   ← auto ID: millisecond_timestamp-sequence
```

The `'*'` tells Redis to generate the ID. You can also supply your own: `XADD learn:events "1-1" ...`

```bash
docker exec mini-baas-redis redis-cli -n 15 \
  XADD learn:events '*' user bob action signup ip 192.168.1.2
```

### XLEN — entry count

```bash
docker exec mini-baas-redis redis-cli -n 15 XLEN learn:events
# (integer) 2
```

### XRANGE — read entries

```bash
# All entries: - is the smallest ID, + is the largest
docker exec mini-baas-redis redis-cli -n 15 XRANGE learn:events - +
```

```text
1) 1) "1782642545394-0"
   2) 1) "user"
      2) "alice"
      3) "action"
      4) "login"
      5) "ip"
      6) "192.168.1.1"
2) 1) "1782642545501-0"
   2) 1) "user"
      2) "bob"
      3) "action"
      4) "signup"
      5) "ip"
      6) "192.168.1.2"
```

### XREAD — read from an offset

```bash
# Read up to 10 entries starting from ID 0 (the beginning)
docker exec mini-baas-redis redis-cli -n 15 XREAD COUNT 10 STREAMS learn:events 0
```

```text
1) 1) "learn:events"
   2) 1) 1) "1782642545394-0"
         2) 1) "user"
            2) "alice"
            ...
```

For blocking read (wait for new entries): `XREAD BLOCK 0 STREAMS learn:events $`
(`$` = only new entries arriving after the command).

---

## Consumer groups

Consumer groups let multiple workers share the processing of a stream, with at-least-once delivery
guarantees. Each entry is delivered to one worker in the group, and must be acknowledged with
`XACK`.

### XGROUP CREATE — create a group

```bash
docker exec mini-baas-redis redis-cli -n 15 \
  XGROUP CREATE learn:events learn:workers 0
# OK
# The '0' means start from the beginning of the stream.
# Use '$' to start from new entries only.
```

### XREADGROUP — consume as a worker

```bash
# consumer1 claims the next undelivered entry
docker exec mini-baas-redis redis-cli -n 15 \
  XREADGROUP GROUP learn:workers consumer1 COUNT 1 STREAMS learn:events ">"
```

```text
1) 1) "learn:events"
   2) 1) 1) "1782642545394-0"
         2) 1) "user"
            2) "alice"
            ...
```

`">"` means "give me entries not yet delivered to this group". Use a specific ID to re-read
entries already delivered but not yet acknowledged.

### XACK — acknowledge processing

```bash
docker exec mini-baas-redis redis-cli -n 15 \
  XACK learn:events learn:workers 1782642545394-0
# (integer) 1
```

Unacknowledged entries remain in the group's **Pending Entry List (PEL)**. Use `XPENDING` to
inspect them.

### Cleanup

```bash
docker exec mini-baas-redis redis-cli -n 15 FLUSHDB
```

---

## Pub/Sub vs Streams comparison

| | Pub/Sub | Streams |
|---|---|---|
| Persistence | None — fire and forget | Durable until trimmed |
| Delivery guarantee | At-most-once | At-least-once (with groups + XACK) |
| Multiple consumers | All receive every message | Consumer groups partition messages |
| Backfill | No — missed = lost | Yes — read from any ID |
| Best for | Live notifications, presence | Event logs, job queues, audit trails |

The grobase realtime engine (osionos-bridge) uses Streams with consumer groups for workspace
events — the persistent `XREADGROUP` connections you see in `CLIENT LIST` are exactly this
pattern.

---

## Gotchas / Docker notes

- **Two terminals for Pub/Sub**: a subscribed client can only run `SUBSCRIBE`, `UNSUBSCRIBE`,
  `PSUBSCRIBE`, `PUNSUBSCRIBE`, `PING`, and `RESET`. Open a second `docker exec` shell for the
  publisher.
- **Stream IDs are time-based**: if the system clock goes backward, `XADD '*'` can fail with
  "ERR The ID specified in XADD is equal or smaller than the target stream top item". Supply an
  explicit ID or use `XADD '*'` immediately after the clock issue passes.
- **`XGROUP CREATE` with `$`**: starting a group at `$` means it only processes entries added
  _after_ group creation. Use `0` to reprocess the full stream from the start.
- **XACK is mandatory** for at-least-once semantics. Unacknowledged entries accumulate in the PEL
  and can be redelivered with `XCLAIM` or `XAUTOCLAIM`.

---

Previous: [02-keys-ttl.md](02-keys-ttl.md) | Next: [04-acl-users.md](04-acl-users.md) | [README](README.md)
