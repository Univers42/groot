# Redis Data Types — CRUD

Redis is a data-structure store: every key holds a typed value and you manipulate it with
type-specific commands. This file covers the five core types with create / read / update / delete
verbs and a practical scenario for each. All commands run in scratch db 15 under the `learn:`
prefix.

## Setup

```bash
# Open scratch shell
docker exec -it mini-baas-redis redis-cli -n 15
```

---

## Strings

The simplest type — a binary-safe byte sequence up to 512 MB. Integers stored as strings can be
atomically incremented.

### CRUD

```text
# Create
SET learn:hello world
# OK

# Read
GET learn:hello
# "world"

# Update — overwrite
SET learn:hello "world!"
# OK

# Append to existing value
APPEND learn:hello " v2"
# (integer) 9   ← new length in bytes

GET learn:hello
# "world! v2"

# Atomic counter (create on first call)
INCR learn:counter
# (integer) 1

INCR learn:counter
# (integer) 2

# Bulk set / get
MSET learn:color red learn:shape circle
MGET learn:color learn:shape
# 1) "red"
# 2) "circle"

# Delete
DEL learn:hello learn:counter learn:color learn:shape
```

### SET with options

```text
# Set with TTL in seconds (create and expire together)
SET learn:session:token "abc123" EX 3600

# Set only if key does NOT already exist (atomic test-and-set)
SET learn:lock "owner:alice" NX EX 30

# Set only if key already EXISTS
SET learn:session:token "newtoken" XX EX 3600
```

### Scenario — page-view counter

```text
SET learn:views:homepage 0
INCR learn:views:homepage
INCR learn:views:homepage
INCR learn:views:homepage
GET learn:views:homepage
# "3"

DEL learn:views:homepage
```

---

## Hashes

A Hash is a map of string field → string value stored under a single key. It is the natural fit
for structured objects (a user record, a product, a config block).

### CRUD

```text
# Create / update fields (multiple at once)
HSET learn:product name "Widget Pro" price "19.99" stock 50
# (integer) 3   ← number of NEW fields created

# Read one field
HGET learn:product name
# "Widget Pro"

# Read all fields
HGETALL learn:product
# 1) "name"
# 2) "Widget Pro"
# 3) "price"
# 4) "19.99"
# 5) "stock"
# 6) "50"

# Increment integer field
HINCRBY learn:product stock 10
# (integer) 60

# Increment float field
HINCRBYFLOAT learn:product price 5.00
# "24.99"

# Delete a field
HDEL learn:product price
# (integer) 1

# Check existence of a field
HEXISTS learn:product price
# (integer) 0   ← field was deleted

# Delete the whole key
DEL learn:product
```

> **Gotcha:** `HINCRBY` requires the field value to be an integer string — it will return an
> error on a float like `"19.99"`. Use `HINCRBYFLOAT` for decimal numbers.

### Scenario — product catalog entry

```text
HSET learn:product:42 name "Widget Pro" sku "WP-042" price "24.99" stock 100 category "tools"
HGET learn:product:42 sku
# "WP-042"
HGETALL learn:product:42
HINCRBY learn:product:42 stock -3
# (integer) 97

DEL learn:product:42
```

---

## Lists

A List is a doubly-linked sequence of strings. `L` prefix = left (head), `R` prefix = right
(tail). Natural queue: push to one end, pop from the other.

### CRUD

```text
# Push to head (LPUSH reverses insertion order)
LPUSH learn:queue task3 task2 task1
# (integer) 3
# Result order: [task1, task2, task3]  (task1 is at head)

# Push to tail
RPUSH learn:queue task4
# (integer) 4
# [task1, task2, task3, task4]

# Read a range (0 = head, -1 = tail)
LRANGE learn:queue 0 -1
# 1) "task1"
# 2) "task2"
# 3) "task3"
# 4) "task4"

# Pop from head (dequeue)
LPOP learn:queue
# "task1"

# Pop from tail
RPOP learn:queue
# "task4"

# Remove specific value (count=0 removes all occurrences)
LREM learn:queue 0 task3
# (integer) 1

# Check current contents
LRANGE learn:queue 0 -1
# 1) "task2"

DEL learn:queue
```

### Scenario — background job queue

```text
# Producer pushes work to the tail
RPUSH learn:jobs:email "send:user:1" "send:user:2" "send:user:3"

# Worker pops from the head (FIFO)
LPOP learn:jobs:email
# "send:user:1"
LPOP learn:jobs:email
# "send:user:2"

DEL learn:jobs:email
```

---

## Sets

A Set is an unordered collection of unique strings. Use it for tag clouds, membership tests, or
finding intersections/unions between groups.

### CRUD

```text
# Create / add members
SADD learn:tags redis nosql database cache
# (integer) 4

# Read all members (order is undefined)
SMEMBERS learn:tags
# 1) "redis"
# 2) "cache"
# 3) "nosql"
# 4) "database"

# Membership test
SISMEMBER learn:tags redis
# (integer) 1

SISMEMBER learn:tags mysql
# (integer) 0

# Remove a member
SREM learn:tags nosql
# (integer) 1

# Set operations — intersection, union, difference
SADD learn:tags2 database memory cache
SINTER learn:tags learn:tags2
# 1) "cache"
# 2) "database"

SUNION learn:tags learn:tags2
# 1) "redis"
# 2) "cache"
# 3) "database"
# 4) "memory"

SDIFF learn:tags learn:tags2
# 1) "redis"

DEL learn:tags learn:tags2
```

### Scenario — article tagging

```text
SADD learn:article:101:tags "backend" "redis" "docker"
SADD learn:article:102:tags "backend" "postgres" "docker"

# Articles that share both tags
SINTER learn:article:101:tags learn:article:102:tags
# 1) "backend"
# 2) "docker"

DEL learn:article:101:tags learn:article:102:tags
```

---

## Sorted Sets

A Sorted Set is like a Set but each member carries a `float` score. Members are always returned
in score order (ascending by default). Perfect for leaderboards, priority queues, and time-series
indexes.

### CRUD

```text
# Add members with scores (ZADD)
ZADD learn:leaderboard 1500 alice 1200 bob 1800 charlie
# (integer) 3

# Read all members, ascending by score
ZRANGE learn:leaderboard 0 -1 WITHSCORES
# 1) "bob"
# 2) "1200"
# 3) "alice"
# 4) "1500"
# 5) "charlie"
# 6) "1800"

# Read descending (top of board first)  — Redis 6.2+ REV option
ZRANGE learn:leaderboard 0 -1 WITHSCORES REV
# 1) "charlie"
# 2) "1800"
# 3) "alice"
# 4) "1500"
# 5) "bob"
# 6) "1200"

# Get a member's score
ZSCORE learn:leaderboard charlie
# "1800"

# Get rank (0-based, ascending)
ZRANK learn:leaderboard alice
# (integer) 1

# Range by score
ZRANGEBYSCORE learn:leaderboard 1400 2000
# 1) "alice"
# 2) "charlie"

# Increment a score
ZINCRBY learn:leaderboard 300 bob
# "1500"

# Remove a member
ZREM learn:leaderboard bob
# (integer) 1

DEL learn:leaderboard
```

### Scenario — game leaderboard

```text
ZADD learn:game:scores 4200 "player:alice" 3850 "player:bob" 5100 "player:diana"

# Top 3
ZRANGE learn:game:scores 0 2 WITHSCORES REV
# 1) "player:diana"
# 2) "5100"
# 3) "player:alice"
# 4) "4200"
# 5) "player:bob"
# 6) "3850"

# Alice finishes a new run
ZINCRBY learn:game:scores 1000 "player:alice"
# "5200"

DEL learn:game:scores
```

---

## Cleanup

```bash
# Wipe all learn: keys in one shot
docker exec mini-baas-redis redis-cli -n 15 FLUSHDB
```

## Gotchas / Docker notes

- **`HINCRBY` vs `HINCRBYFLOAT`**: `HINCRBY` only accepts integers; use `HINCRBYFLOAT` for
  decimal values.
- **`LPUSH` argument order**: `LPUSH key a b c` pushes `a`, then `b`, then `c` to the head, so
  the final order in the list is `[c, b, a]`. Push one item at a time if insertion order matters.
- **`ZRANGEBYSCORE` vs `ZRANGE ... BYSCORE`**: Redis 6.2 unified range commands into `ZRANGE`
  with `BYSCORE`/`BYLEX`/`REV` options. Both forms work in 7.2 but `ZRANGEBYSCORE` is considered
  legacy.
- **`SMEMBERS` on large sets**: returns all members in a single reply. On large sets (millions of
  members) prefer `SSCAN` with a cursor, same pattern as `SCAN` for keys.

---

Previous: [00-connect.md](00-connect.md) | Next: [02-keys-ttl.md](02-keys-ttl.md) | [README](README.md)
