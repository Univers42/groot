# Security

MariaDB security rests on three pillars: **who can connect** (host-based access control), **what they can do** (grants — covered in [05-permissions-grants.md](05-permissions-grants.md)), and **how the connection is protected** (TLS, auth plugins). This file covers the remaining two.

## Auth plugins — what is in this container

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW PLUGINS;" | grep -i auth'
```

```
mysql_native_password   ACTIVE  AUTHENTICATION  NULL  GPL
mysql_old_password      ACTIVE  AUTHENTICATION  NULL  GPL
unix_socket             ACTIVE  AUTHENTICATION  NULL  GPL
```

Only three plugins are active. `ed25519` and `caching_sha2_password` (Oracle MySQL 8.0 default) are NOT installed in this image.

### Plugin behaviour

| Plugin | How it works | When to use |
|---|---|---|
| `mysql_native_password` | SHA1 challenge-response | Default in this stack; compatible with all client libraries |
| `mysql_old_password` | Pre-4.1 DES hash — **insecure** | Legacy compat only — never use for new accounts |
| `unix_socket` | Matches the OS user running the socket connection | Ideal for same-host scripts, avoids passwords entirely |

### Create a user with unix_socket auth

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"dbadmin\"@\"localhost\"
  IDENTIFIED VIA unix_socket;
SHOW GRANTS FOR \"dbadmin\"@\"localhost\";
"'
```

With this config, `dbadmin@localhost` can only connect when the OS user is also `dbadmin` — no password prompt, no password in scripts. This is how the MariaDB system root often works inside containers:

```bash
# Connect as root without a password flag (works because the socket matches):
docker exec mini-baas-mariadb mariadb -uroot
```

### Set or change the auth plugin for an existing account

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Switch an account from native password to unix_socket
ALTER USER \"dbadmin\"@\"localhost\" IDENTIFIED VIA unix_socket;

-- Switch back to password auth
ALTER USER \"dbadmin\"@\"localhost\" IDENTIFIED BY \"newPassword1!\";
"'
```

## TLS / SSL

### Check TLS status

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW VARIABLES LIKE \"%ssl%\";"'
```

```
Variable_name     Value
have_openssl      YES
have_ssl          YES
ssl_ca
ssl_cert
ssl_capath
ssl_cipher
ssl_crl
ssl_crlpath
ssl_key
version_ssl_library  OpenSSL 3.3.7 7 Apr 2026
```

`have_ssl=YES` means TLS is compiled in. The empty `ssl_cert`/`ssl_key` variables mean no server TLS certificate is configured — connections over the UNIX socket are encrypted at the OS level, but TCP connections are unencrypted unless a cert is provided.

```bash
# Verify your current session's encryption (interactive session):
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "\s"' | grep SSL
```

```
SSL: Cipher in use is TLS_AES_256_GCM_SHA384, cert is OK
```

### Require TLS for a specific user

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"tls_user\"@\"%\" IDENTIFIED BY \"tlsPass1!\" REQUIRE SSL;
SHOW CREATE USER \"tls_user\"@\"%\"\G
"'
```

With `REQUIRE SSL`, this user's TCP connections are rejected if the connection is not TLS-encrypted. Connections from the same host via UNIX socket still work (socket connections are always secure).

To require a specific cipher:

```sql
-- Pattern (unverified here — requires server TLS cert to be meaningful):
CREATE USER 'secure_user'@'%' IDENTIFIED BY 'pass' REQUIRE SSL
  AND CIPHER 'TLS_AES_256_GCM_SHA384';
```

## Host-based access control

MariaDB matches connection attempts against `mysql.user` rows in specificity order: exact hostname > subnet pattern > `%`. The first match wins.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SELECT user, host, plugin FROM mysql.user ORDER BY user, host;
"'
```

```
User          Host            plugin
bob_reader    %               mysql_native_password
mini_baas     %               mysql_native_password
root                          (empty — socket only)
root          127.0.0.1       (empty — socket)
root          ::1             (empty — socket)
root          localhost       mysql_native_password
root          %               mysql_native_password
shop_reader                   (role, no login)
```

The `root@%` entry (with a password) means root can connect from any host via TCP — this is appropriate for development but should be locked down in production.

## Removing over-broad grants

### Check for anonymous users

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SELECT user, host FROM mysql.user WHERE user = \"\";
"'
```

In this container the query returns no rows — no anonymous users exist. If they did appear, remove them:

```sql
-- Pattern: remove anonymous user (run only if the query above shows rows)
DROP USER ''@'localhost';
DROP USER ''@'%';
```

### Restrict root to localhost only

```bash
# Pattern (unverified here — would break this demo's remote root access):
# docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
# DROP USER \"root\"@\"%\";
# FLUSH PRIVILEGES;
# "'
```

In this dev stack `root@%` is intentional (allows `docker exec` access from the host without `-it`). In production, drop it and restrict root to socket-only access.

## mysql_secure_installation equivalents

`mysql_secure_installation` is a convenience script that performs a sequence of hardening steps. Here are the individual commands for each step — run manually in Docker:

```bash
# 1. Set a root password (already set in this container)
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
ALTER USER \"root\"@\"localhost\" IDENTIFIED BY \"StrongNewPass1!\";
"'

# 2. Remove anonymous users (already done in this image)
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DELETE FROM mysql.user WHERE user = \"\";
FLUSH PRIVILEGES;
"'

# 3. Disallow remote root login
# docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
# DELETE FROM mysql.user WHERE user = \"root\" AND host != \"localhost\";
# FLUSH PRIVILEGES;
# "'

# 4. Remove the test database
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP DATABASE IF EXISTS test;
"'
```

## Password validation

MariaDB does not enable a password validation plugin by default in this image. In production, install and configure `simple_password_check` or `cracklib_password_check`:

```sql
-- Pattern (unverified here — plugin not present in this image):
-- INSTALL PLUGIN simple_password_check SONAME 'simple_password_check';
-- SET GLOBAL simple_password_check_digits = 1;
-- SET GLOBAL simple_password_check_letters_same_case = 1;
-- SET GLOBAL simple_password_check_minimal_length = 12;
```

Until a validation plugin is active, MariaDB accepts any string as a password (including empty string).

## Practical hardening checklist

Use this checklist when preparing the database for a non-development environment:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- 1. No anonymous accounts
SELECT CONCAT(\"Anonymous user found: \", user, \"@\", host) AS warning
FROM mysql.user WHERE user = \"\";

-- 2. No test database
SELECT schema_name FROM information_schema.schemata WHERE schema_name = \"test\";

-- 3. Root has a non-empty password hash
SELECT user, host, (password = \"\") AS no_password
FROM mysql.user WHERE user = \"root\" AND (password = \"\");

-- 4. Every application account scoped to specific DB (not *.*)
SELECT u.user, u.host, d.db, d.Select_priv
FROM mysql.user u
LEFT JOIN mysql.db d ON d.user = u.user AND d.host = u.host
WHERE u.user NOT IN (\"root\",\"mariadb.sys\") AND u.user != \"\"
ORDER BY u.user;
"'
```

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP USER IF EXISTS \"dbadmin\"@\"localhost\";
DROP USER IF EXISTS \"tls_user\"@\"%\";
"'
```

## Gotchas / Docker notes

- **`ed25519` is not installed** in `ghcr.io/univers42/grobase-mariadb:latest`. Documentation or tutorials that reference `IDENTIFIED VIA ed25519` will fail with `ERROR 1524: Plugin 'ed25519' is not loaded`. Use `mysql_native_password` or `unix_socket` in this stack.
- **UNIX socket vs TCP root**: the `root` entries with an empty host (`''`) in `mysql.user` are socket-auth entries from container initialization. The `root@localhost` with `mysql_native_password` is the password-protected entry. Both must stay for normal `docker exec` operations.
- **`REQUIRE SSL` on UNIX socket connections**: the `REQUIRE SSL` constraint does not apply to socket connections — a socket connection is always considered secure regardless of the TLS requirement. This is by design and documented MariaDB behaviour.
- **No `caching_sha2_password`**: this is the default in Oracle MySQL 8.0+ and requires clients that support it. The MariaDB 11.4 image ships `mysql_native_password` as default. If you connect a MySQL 8.0 client to this server, it will fall back to `mysql_native_password` automatically.

---

Previous: [05-permissions-grants.md](05-permissions-grants.md) | Next: [07-backup-restore.md](07-backup-restore.md)
