# Keys, TTL, and Namespacing

Every Redis value lives under a key. This file covers how to inspect, rename, expire, and iterate
keys safely — including the critical difference between `KEYS` (dangerous in production) and
`SCAN` (safe).

## Setup

```bash
docker exec -it mini-baas-redis redis-cli -n 15
```

---

## Key inspection

### EXISTS — does the key exist?

```text
SET learn:check "here"

EXISTS learn:check
# (integer) 1

EXISTS learn:missing
# (integer) 0

# Check multiple keys at once
EXISTS learn:check learn:missing
# (integer) 1   ← count of keys that exist
```

### TYPE — what data structure is stored?

```text
SET   learn:t:str   "hello"
HSET  learn:t:hash  field value
LPUSH learn:t:list  item
SADD  learn:t:set   member
ZADD  learn:t:zset  1.0 member

TYPE learn:t:str
# string
TYPE learn:t:hash
# hash
TYPE learn:t:list
# list
TYPE learn:t:set
# set
TYPE learn:t:zset
# zset
```

### OBJECT ENCODING — internal encoding

Redis uses multiple internal encodings per type, chosen automatically based on value size.

```text
# Small integer string → "int"
SET learn:t:int 42
OBJECT ENCODING learn:t:int
# int

# Small set → "listpack" (compact array); large set → "hashtable"
SADD learn:t:smallset a b c
OBJECT ENCODING learn:t:smallset
# listpack

# Small sorted set → "listpack"; large → "skiplist"
```

Encoding affects memory usage and performance — smaller encodings are more memory-efficient.

---

## Key deletion

### DEL — synchronous delete

```text
DEL learn:check learn:t:str
# (integer) 2   ← count of keys actually deleted
```

### UNLINK — asynchronous delete (non-blocking)

```text
# Returns immediately; the actual memory reclaim happens in background
UNLINK learn:t:hash learn:t:list learn:t:set learn:t:zset learn:t:int learn:t:smallset
# (integer) 6
```

`UNLINK` is preferred over `DEL` for large keys (big Lists, Hashes, Sets) because it avoids a
blocking sweep of the memory allocator on the main thread.

### RENAME

```text
SET learn:old:key "value"
RENAME learn:old:key learn:new:key
# OK

GET learn:new:key
# "value"

# RENAMENX only renames if destination does NOT exist
RENAMENX learn:new:key learn:another
# (integer) 1   ← success; (integer) 0 if destination existed

DEL learn:another
```

---

## KEYS vs SCAN

### KEYS — simple but dangerous in production

```text
KEYS "learn:*"
```

```text
1) "learn:counter"
2) "learn:hello"
...
```

`KEYS` **blocks the entire Redis server** until it has scanned every key. On a db with millions
of keys this can block all clients for seconds. On the live container db 0 has ~2 500 keys —
safe to run there now, but the habit is bad. **Never use `KEYS *` in production scripts.**

### SCAN — cursor-based, non-blocking

```text
# First call: cursor=0, returns [next_cursor, [keys]]
SCAN 0 MATCH "learn:*" COUNT 100
# 1) "0"          ← next cursor (0 means iteration complete)
# 2) 1) "learn:counter"
#    2) "learn:hello"
#    ...
```

`SCAN` returns a cursor. Keep calling with the returned cursor until it comes back as `0`. `COUNT`
is a hint (not a guarantee) about how many entries to check per call.

```bash
# Host-side: --scan iterates automatically until cursor wraps to 0
docker exec mini-baas-redis redis-cli -n 15 --scan --pattern "learn:*"
```

Type-specific scan variants: `HSCAN`, `SSCAN`, `ZSCAN` — same cursor pattern, for Hash/Set/ZSet
fields.

---

## Expiry / TTL

Keys can have a time-to-live (TTL). When TTL reaches zero, the key is automatically deleted.

### Setting expiry

```text
# At creation: SET key value EX seconds
SET learn:cache:token "eyJhbGciOiJIUzI1NiJ9" EX 3600
# OK

# On an existing key: EXPIRE (seconds) or PEXPIRE (milliseconds)
SET learn:cache:item "data"
EXPIRE  learn:cache:item 120
PEXPIRE learn:cache:item 120000

# Set expiry as a Unix timestamp: EXPIREAT / PEXPIREAT
EXPIREAT learn:cache:item 1800000000
```

### Inspecting TTL

```text
TTL learn:cache:token
# (integer) 3598   ← seconds remaining

PTTL learn:cache:token
# (integer) 3597891   ← milliseconds remaining

# A key with no TTL returns -1
SET learn:persistent "forever"
TTL learn:persistent
# (integer) -1

# A key that does not exist returns -2
TTL learn:missing
# (integer) -2
```

### Removing expiry

```text
PERSIST learn:cache:token
# (integer) 1
TTL learn:cache:token
# (integer) -1   ← no longer expires
```

### Scenario — cache entry that auto-expires

```text
# Cache a rendered HTML snippet for 5 minutes
SET learn:cache:page:home "<html>...</html>" EX 300

# Check remaining life
TTL learn:cache:page:home
# (integer) 299

# If you update the page, overwrite the key (TTL resets on SET)
SET learn:cache:page:home "<html>v2...</html>" EX 300

# Invalidate early
DEL learn:cache:page:home
```

---

## Namespacing conventions

Redis has no built-in namespaces or schemas — the key name is the only structure. Standard
conventions used in this repo:

| Pattern | Purpose |
|---------|---------|
| `app:entity:id:field` | Hierarchical namespace: app → entity type → ID → optional sub-field |
| `learn:*` | All practice keys in this guide |
| `sess:*` | Session tokens (short TTL) |
| `cache:*` | Cached computed values (short TTL) |
| `realtime:*` | Stream keys used by the grobase realtime engine |

Colons (`:`) are the universal separator. The colon has no special meaning to Redis — it is purely
a naming convention.

---

## Cleanup

```bash
# Remove only the learn: keys created in this file
docker exec mini-baas-redis redis-cli -n 15 FLUSHDB
```

## Gotchas / Docker notes

- **`KEYS *` in production = bad**: use `--scan` or `SCAN` with a cursor. Save `KEYS` for
  quick ad hoc checks on tiny datasets.
- **`SET` resets TTL**: calling `SET` on a key that already has an expiry removes the TTL unless
  you pass `KEEPTTL` or `EX`/`PX` again.
- **`RENAME` to an existing key**: `RENAME` deletes the destination first (atomically), so data
  at the destination is lost. `RENAMENX` is the safe alternative.
- **`DEL` vs `UNLINK`**: for thousands of fields in a single key (large Hash, List, etc.),
  `UNLINK` prevents the main event loop from stalling.

---

Previous: [01-data-types-crud.md](01-data-types-crud.md) | Next: [03-pubsub-streams.md](03-pubsub-streams.md) | [README](README.md)
