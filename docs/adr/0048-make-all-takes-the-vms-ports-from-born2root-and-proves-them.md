# 0048. make all takes the VM's ports from born2root and proves them

Status: accepted, 2026-11-05.

## Context

`make all` failed on a colleague's machine with port errors. born2root already moved a busy forward,
but only the VM directory knew where it landed, groot assumed 4242 and 8443, and the VM's origin
lists named default frontend ports, so a moved frontend was refused.

## Decision

- born2root records each start's host ports in `~/.config/born2root/<alias>-ports.env`. groot reads
  that file. The old 8443 stands only for a VM with no record, and only once proved.
- `datacenter-chain` stops `make all` if the alias, the pinned key, the WAF or a frontend port
  disagree. A port counts when the service on it presents a certificate this VM's CA signed.
- `datacenter-origins` adds this host's frontend origins to `KONG_CORS_ORIGIN_DEV_LIST`,
  `REALTIME_ALLOWED_ORIGINS` and `GOTRUE_URI_ALLOW_LIST` in the VM, and recreates kong, gotrue and
  realtime from their compose labels. It writes nothing when the running containers already allow
  them.

## Risk verdict

PROCEED-WITH-CONDITIONS, 2026-11-05, on `89309292`. Blast radius 4, reversibility 2, cost on failure
3, confidence 3. Conditions, all met in the commit that adds this record:

1. No recreate and no ports refresh on a host with `.env.public`, the mark of serving production.
2. The refresh runs only for the default alias and only for this user's QEMU.
3. An origin is built only from a value that is a port.
4. A failed recreate says the services may be partly recreated.
5. Only the three origin keys leave the guest.

## Consequences

- The lists only grow: an origin a moved frontend has left stays allowed until removed by hand.
- `API_EXTERNAL_URL`, `SUPABASE_URL` and `SUPABASE_PUBLIC_URL` in the VM keep 8443 when the WAF moves,
  so a link built from them points at the old port. Google sign-in is not configured on this path.
- Ports resolved before the VM starts can collide with its forwards; the chain stops and a second
  `make all` resolves them.
