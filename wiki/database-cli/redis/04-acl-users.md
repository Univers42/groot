# ACL Users and Authentication

Redis 6+ ships a full Access Control List (ACL) system: each user has its own password(s),
allowed commands, and key/channel patterns. The live container runs with a single `default` user
that has no password and full access — a typical dev setup. This file covers how to inspect,
create, test, and clean up ACL users.

## Current state on this container

```bash
docker exec mini-baas-redis redis-cli ACL WHOAMI
# "default"

docker exec mini-baas-redis redis-cli ACL LIST
# user default on nopass sanitize-payload ~* &* +@all
```

Breaking down the `default` rule:
- `on` — enabled
- `nopass` — no password required
- `sanitize-payload` — strips dangerous payloads from error messages
- `~*` — access to all key patterns
- `&*` — access to all channel patterns (Pub/Sub)
- `+@all` — all commands allowed

---

## ACL inspection commands

### ACL GETUSER

```bash
docker exec mini-baas-redis redis-cli ACL GETUSER default
```

```text
flags
on
nopass
sanitize-payload
passwords
               ← empty (nopass)
commands
+@all
keys
~*
channels
&*
selectors
```

### ACL CAT — list command categories

```bash
docker exec mini-baas-redis redis-cli ACL CAT
```

```text
keyspace
read
write
set
sortedset
list
hash
string
...
```

```bash
# Commands within a category
docker exec mini-baas-redis redis-cli ACL CAT read
```

---

## ACL SETUSER — create or modify a user

### Scenario — read-only user for `learn:*` keys

```bash
docker exec mini-baas-redis redis-cli ACL SETUSER learn-reader \
  on \
  ">readpass123" \
  "~learn:*" \
  "+GET" "+HGET" "+HGETALL" "+LRANGE" "+SMEMBERS" "+ZRANGE" "+PING"
# OK
```

Flags explained:
- `on` — account is active
- `>readpass123` — set a password (the `>` prefix means "add this password")
- `~learn:*` — key pattern: this user can only touch keys starting with `learn:`
- `+GET +HGET ...` — whitelist specific commands

Verify it was created:

```bash
docker exec mini-baas-redis redis-cli ACL LIST
# user default on nopass sanitize-payload ~* &* +@all
# user learn-reader on sanitize-payload #<hash> ~learn:* resetchannels -@all +get +hget +hgetall +lrange +smembers +zrange +ping
```

Passwords are stored as SHA-256 hashes in `ACL LIST` — never in plain text.

### Testing the new user

```bash
# Connect as learn-reader — must pass --user and --pass
docker exec mini-baas-redis redis-cli \
  --user learn-reader --pass readpass123 -n 15 GET learn:hello
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# "world"

# Attempt a forbidden command — SET is not in the whitelist
docker exec mini-baas-redis redis-cli \
  --user learn-reader --pass readpass123 -n 15 SET learn:denied test
# NOPERM User learn-reader has no permissions to run the 'set' command
```

> **Gotcha:** the `learn-reader` user does not have `+SELECT`, so `-n 15` triggers a
> `NOPERM` for the implicit `SELECT 15`. To allow db selection, add `+SELECT` to the ACL rule.
> For one-shot commands the `-n` flag issues `SELECT` before your command — without permission
> to `SELECT`, the connection will fail. Test the user by connecting without `-n` and issuing
> `SELECT 15` explicitly, or add `+SELECT` to the ACL.

### AUTH — authenticate inside a session

```bash
docker exec -it mini-baas-redis redis-cli

127.0.0.1:6379> AUTH learn-reader readpass123
# OK

127.0.0.1:6379> ACL WHOAMI
# "learn-reader"
```

Or authenticate at connection time:

```bash
docker exec -it mini-baas-redis redis-cli -u "redis://learn-reader:readpass123@127.0.0.1:6379"
```

---

## Adding a password to the default user

The dev container uses `nopass` for the `default` user. To add a real password:

```bash
# In a one-shot (this container — verification only, not applied in this guide)
# docker exec mini-baas-redis redis-cli ACL SETUSER default >StrongPass!2026

# To authenticate after setting a password:
# docker exec mini-baas-redis redis-cli -a StrongPass!2026 PING
# (or: AUTH default StrongPass!2026 inside interactive mode)
```

`requirepass` in `redis.conf` is equivalent but applies only to the `default` user. ACL is more
flexible. Both are documented here as patterns — the live container has no password set.

---

## Resetting / deleting a user

### Remove a password (without deleting the user)

```bash
# < prefix removes a password; <hash> or plain text
docker exec mini-baas-redis redis-cli ACL SETUSER learn-reader "<readpass123"
# nopass flag can also be added: ACL SETUSER learn-reader nopass
```

### Disable a user (keep definition, deny all logins)

```bash
docker exec mini-baas-redis redis-cli ACL SETUSER learn-reader off
```

### Delete a user entirely

```bash
docker exec mini-baas-redis redis-cli ACL DELUSER learn-reader
# (integer) 1

docker exec mini-baas-redis redis-cli ACL LIST
# user default on nopass sanitize-payload ~* &* +@all
```

---

## ACL user definition in redis.conf

For persistence across restarts, put users in `redis.conf` (or an `aclfile`). The live container
uses no `aclfile` (config_file is empty) — ACL changes survive only as long as the container is
running unless saved with `ACL SAVE` (if an aclfile is configured).

```text
# redis.conf equivalent of the command above
user learn-reader on >readpass123 ~learn:* -@all +get +hget +hgetall +lrange +smembers +zrange +ping
```

---

## Gotchas / Docker notes

- **`--user` / `--pass` and `-n`**: using `-n <db>` with a restricted user causes a `NOPERM` for
  the implicit `SELECT` unless `+SELECT` is in the user's command list.
- **No password ≠ no security**: the live container uses `nopass` because it is not publicly
  exposed (it is on the internal `mini-baas` Docker network). In a publicly reachable service,
  always set a strong password and limit the default user to `+AUTH` only.
- **Password hashes in ACL LIST**: Redis shows SHA-256 hashes, not plain-text passwords. Do not
  mistake the hash for plain-text when scripting.
- **ACL SAVE**: only works if `aclfile` is set in config. Without it, `ACL SETUSER` changes are
  in-memory and lost on container restart.
- **`-a` flag warning**: `redis-cli -a password` emits a warning because the password is visible
  in process listings. Use environment variable `REDISCLI_AUTH` or pipe AUTH for CI pipelines.

---

Previous: [03-pubsub-streams.md](03-pubsub-streams.md) | Next: [05-security-persistence.md](05-security-persistence.md) | [README](README.md)
