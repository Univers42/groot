# A tenant-owned database on the platform docker network is out of scope

- Decided: 2026-11-16 · by devil ([ADR 0050](../docs/adr/0050-the-inception-mounts-move-to-a-vm-copy-on-its-own-internal-network.md))
- Holds while: tenant Workers on the VM keep `net: "inherit"` and the platform MariaDB image ships SSRF-capable plugins

## The concept

Run a tenant's database, here the 42-Inception MariaDB copy for tenant `agency`, as a container attached to
`mini-baas_mini-baas`, so the data plane reaches it by service name with no extra network.

## Why not

- `mini-baas-functions` is on that network, and `FUNCTIONS_NET_ALLOWLIST_ENABLED` is unset. Every tenant's
  Worker can therefore open TCP to the database (`infra/docker/services/functions-runtime/src/server.ts:92-99`).
  The database's own credentials are its only guard.
- `grobase-mariadb` ships `ha_connect.so`, `ha_federatedx.so` and `ha_spider.so`. A tenant user with global
  privileges turns the server into an SSRF pivot into 35 platform containers.
- A foreign endpoint stops docker from removing or recreating the platform network. That couples
  `make down` (`orchestrators/makes/20-stack.mk:22-23`) to another project.

## Prior requests

- 2026-11-16 (inception-restore plan, P2): attach `agency-inception-db` to `mini-baas_mini-baas` only.

## Reopen when

Two things must both be true on the VM:

- the functions network jail is on (`FUNCTIONS_NET_ALLOWLIST_ENABLED=1`, gate m197);
- the data plane's dial guard is enforced with a per-host rule for the tenant database.

Then re-decide from scratch.
