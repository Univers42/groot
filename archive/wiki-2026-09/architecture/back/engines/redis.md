Redis is a very fast-in-memory databse used for cache, sessions, rate limiting, and queues.

# without redis

EVERY REQUEST Hits the database

Client -> API -> Psql-> API -> client

```js
const user = await db.query("SELECT * FROM users WHERER id = $1", [id]);
```

slow for repeated reads
- db gets overload
- expensive scaling


with redis frequently used data is cached:

Client → API → Redis (fast?)
               ├─ YES → return instantly
               └─ NO  → PostgreSQL → store in Redis

```js
let user = await redis.get(`user:${id}`);
if (!user) {
    user = await db.query("SELECT * FROM users WHERE id = $1", [id]);
    await redis.set(`user:${id}`, JSON.stringify(user));
}

```

in one line:
- without redis: DB does all the work
- with REDIS: Redis handles repeated/fast access data DB is source of truth.