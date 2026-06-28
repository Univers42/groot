# 06 — Security: Insecure vs Secure Mode

This node runs CockroachDB in **insecure mode** — no TLS, no password authentication. That is intentional for a dev cluster. This file explains what insecure mode means, what secure mode looks like (documented as patterns, unverified on this node), and how to reason about security for anything beyond local development.

## Current state: insecure mode

The container was started with `--insecure`. Verify:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "SHOW CLUSTER SETTING server.host_based_authentication.configuration;"
```

In insecure mode, **any client that can reach port 26257 can connect as any user, including root**, with no password. This is why the node is not exposed to public networks.

Check how the container port is bound:

```bash
docker port mini-baas-cockroach
```

```
8080/tcp  -> 0.0.0.0:28080
26257/tcp -> 0.0.0.0:26257
```

The SQL port is bound to `0.0.0.0` inside the container. In this stack it is accessible only within the `mini-baas_mini-baas` Docker network. Never forward port 26257 to a public interface in insecure mode.

## Why insecure is dev-only

- No TLS: credentials and query data travel in plaintext.
- No authentication: `CREATE USER` still works but passwords are rejected (`WITH PASSWORD` raises an error in insecure mode).
- No audit trail by default.
- `root` is always accessible to anyone who can reach the port.

Use insecure mode only for local development and CI sandboxes where the network boundary is trusted.

## Secure mode — pattern (unverified on this insecure node)

In production you run `cockroach start` **without** `--insecure` and point it to a directory of TLS certificates. The `cockroach cert` subcommand generates them.

### Certificate hierarchy

```
CA certificate
├── node certificates  (one per cluster node)
└── client certificates (one per user/service)
```

### Generating certs — pattern (unverified here)

```bash
# 1. Create the CA
docker exec mini-baas-cockroach cockroach cert create-ca \
  --certs-dir=/certs --ca-key=/certs/ca.key

# 2. Create a node certificate
docker exec mini-baas-cockroach cockroach cert create-node \
  localhost 127.0.0.1 <node-hostname> \
  --certs-dir=/certs --ca-key=/certs/ca.key

# 3. Create a client certificate for root
docker exec mini-baas-cockroach cockroach cert create-client root \
  --certs-dir=/certs --ca-key=/certs/ca.key

# 4. Create a client certificate for an app user
docker exec mini-baas-cockroach cockroach cert create-client shop_api_svc \
  --certs-dir=/certs --ca-key=/certs/ca.key
```

### Connecting in secure mode — pattern (unverified here)

```bash
docker exec -it mini-baas-cockroach cockroach sql \
  --certs-dir=/certs --user=root

# One-shot with cert-based auth:
docker exec mini-baas-cockroach cockroach sql \
  --certs-dir=/certs --user=shop_api_svc \
  -e "SELECT current_user();"
```

### Passwords in secure mode — pattern (unverified here)

```sql
CREATE USER shop_user WITH PASSWORD 'strong-passphrase';
```

Use environment variables or a secrets manager — never hardcode passwords in scripts or documentation.

## RBAC and least privilege

CockroachDB enforces role-based access control (RBAC). The principle to apply:

1. Create roles named after capabilities: `shop_reader`, `order_writer`, `admin_ops`.
2. Grant object privileges to roles, not directly to users.
3. Grant roles to service accounts and human users.
4. Never grant `admin` to application service accounts.

See [04-users-roles.md](04-users-roles.md) and [05-permissions-grants.md](05-permissions-grants.md) for the full privilege layering recipe.

## Network security in this stack

CockroachDB runs inside the `mini-baas_mini-baas` Docker network. Application containers connect using the service DNS name:

```
host: mini-baas-cockroach
port: 26257
```

No external firewall rule is needed — Docker network isolation keeps the port internal. The host port mapping (`0.0.0.0:26257`) exists only for tooling convenience on the dev machine; close it in production or switch to a named binding on `127.0.0.1`.

## Audit logging — pattern (unverified here)

CockroachDB supports structured audit logging for DML operations. Enable it with a cluster setting:

```sql
-- pattern (unverified here)
SET CLUSTER SETTING server.auth_log.sql_connections.enabled = true;
SET CLUSTER SETTING server.auth_log.sql_sessions.enabled    = true;
```

Audit log output goes to the node's log directory (configurable with `--log-dir`). In Docker, forward it to stdout or a mounted volume.

## DB Console access

The admin UI at `http://localhost:28080` is also unauthenticated in insecure mode. It exposes cluster internals (statements, ranges, jobs, users). Do not expose this port to untrusted networks.

## Gotchas / Docker notes

- **`--insecure` and `--certs-dir` are mutually exclusive.** You cannot mix them in the same start command.
- **Rotating certs in a live cluster** requires restarting nodes one at a time (rolling restart). The cluster stays available throughout.
- **`cockroach cert list`** inspects an existing cert directory to show expiry dates and what each cert authorizes.
- **No `pg_hba.conf`.** CockroachDB handles host-based authentication via cluster settings (`server.host_based_authentication.configuration`), not a flat file.
- **The `admin` role is not the same as the Linux `root` user.** In CockroachDB, `root` is a SQL superuser but the cluster process itself runs as a non-root OS user inside the container.

---

← [05-permissions-grants.md](05-permissions-grants.md) | [07-backup-restore.md](07-backup-restore.md) →
