# Fresh-start build log

A from-scratch bring-up of `ft_transcendence` ("Track Binocle") following
[`FRESH-START-AGENT-PROMPT.md`](FRESH-START-AGENT-PROMPT.md), run end-to-end by a Claude Code agent.
This log records every error encountered during `make all` and the exact fix applied, plus the final
6-engine data verification.

**Outcome:** ✅ stack is up and healthy, all 6 engines' data restored. 36 containers running, 34
healthy; the 2 "unhealthy" are confirmed **false-unhealthy** (functional services, broken healthcheck
definitions — details below).

## Run context

- **Date:** 2026-06-27
- **Path:** with-vault (identity present at `~/.config/42ctl/` — both `keystore.v42` and
  `contract-default.tok`)
- **Host:** Linux, Docker 29.1.3, data-root `/var/lib/docker` on `/dev/nvme0n1p7` (116 GB free), git 2.53.0
- **Command:** `FT_PASSPHRASE='Grobase-Vault-2026!' make all` (default `GROBASE_EDITION=migrate`)

## Prerequisite checks (all passed)

| Check | Result |
| --- | --- |
| Docker running | 29.1.3 |
| Data-root on big disk | `/dev/nvme0n1p7`, 116 GB free (17% used) |
| git | 2.53.0 |
| vault42 identity | `keystore.v42` (498 B) + `contract-default.tok` (182 B) both present |
| Fresh state | no containers running, no `mini-baas` network |

`make all` then ran clean through: submodule sync → vault42 secret pull → certs → backend (6 engines)
→ **fail-safe data restore (all engines empty → restored)** → frontends → healthcheck → showcase.
The root pipeline exited **0** and printed the clickable URL list.

## Final verification — all 6 engines (the success bar)

| Engine | Check | Result | Expected |
| --- | --- | --- | --- |
| **Postgres** | `SELECT count(*) FROM osionos_pages` | **350** ✓ | 350 |
| **MySQL** | tables in `ops` schema | **4** ✓ | populated |
| **Mongo** | `activity.events` document count | **30000** ✓ | ~30000 |
| **MSSQL** | tables in `finance` | **5** ✓ | ~5 |
| **DynamoDB** | `list-tables` | **alerts, device_events, devices (3)** ✓ | 3 |
| **MinIO** | object count | **67** ✓ | ~67 |

Frontend/root healthcheck: website `https://localhost:4322`, osionos `https://localhost:3001`, bridge
`https://localhost:4000`, auth-gateway `https://localhost:8787/api/auth` (HTTP 200), grobase BaaS
`http://127.0.0.1:8000/auth/v1/health` (200). Login: `dev.pro.photo / Osionos123!`.

---

## Errors encountered & fixes

### 1. WAF (`mini-baas-waf`) crash-loop — TLS key unreadable  — REAL, FIXED

**Symptom:** `mini-baas-waf` stuck in `Restarting (1)`. Container log:
```
nginx: [emerg] cannot load certificate key "/run/secrets/localhost_key":
  BIO_new_file() failed (SSL: ... Permission denied: fopen(/run/secrets/localhost_key, r))
```
Earlier, during `make certs`, the cert generator had warned:
```
Warning: could not set server key group to WAF gid 101; WAF may not read .../localhost-key.pem.
```

**Root cause:** `apps/grobase/scripts/certs/generate-localhost-cert.sh` (lines 112–116) tries to
`chgrp 101` the server key so the WAF's nginx group can read it, then `chmod 640`. On a normal host
the cert step runs as the unprivileged user (uid 1000), which **cannot** `chgrp` to gid 101, so the
script falls into its `else` branch and leaves the key `chmod 600 owner-only`. The key is delivered
to the WAF as Docker secret `localhost_key` (`docker-compose.yml: secrets.localhost_key.file:
certs/localhost-key.pem`), and nginx (running as gid 101) then can't read it → `[emerg]` → restart
loop.

**Fix applied (runtime, this machine):**
```bash
chmod 0644 apps/grobase/certs/localhost-key.pem
docker restart mini-baas-waf
```
→ `mini-baas-waf` came up `healthy` ("Configuration complete; ready for start up", no `[emerg]`). The
key is a **localhost-only dev CA-signed key**, so world-readable is acceptable for local dev.

**Recommended durable fix (grobase repo — not auto-applied):** the `chgrp` fallback in
`scripts/certs/generate-localhost-cert.sh` should make the key readable by the WAF when `chgrp 101`
isn't possible, instead of locking it to `0600`:
```sh
# scripts/certs/generate-localhost-cert.sh, the chgrp else-branch (~line 114)
else
  chmod 644 "$SERVER_KEY"   # was: chmod 600  → WAF (nginx gid 101) couldn't read it on non-root hosts
  printf 'Note: could not chgrp key to WAF gid %s (needs root); using 0644 for local dev.\n' "${MINI_BAAS_WAF_TLS_GID:-101}" >&2
fi
```
Without this, the WAF crash-loop **recurs on every `make certs` / `make all`** (the key is
regenerated `0600`). The runtime `chmod` above is a per-run workaround.

### 2. `mini-baas-postgrest` reported `unhealthy` — FALSE ALARM (service functional)

**Symptom:** container `unhealthy`; healthcheck output `wget: can't connect to remote host: Connection refused`.

**Root cause:** PostgREST is fully up — `netstat` shows it `LISTEN` on `0.0.0.0:3000` (IPv4) and its
log reports "Schema cache loaded **114 Relations**, 68 Relationships, 23 Functions" after the data
restore. The healthcheck is `["CMD","/bin/busybox","wget","-qO-","http://localhost:3000/"]`. Inside
the container `localhost` resolves to **IPv6 `::1`** first, but PostgREST binds **IPv4-only**
(`0.0.0.0`), so the IPv6 connect is refused. (Same IPv4-only/`localhost`→IPv6 trap the README flags
for Kong / Desktop builds.)

**Proof of health:** `wget http://127.0.0.1:3000/` (IPv4) inside the container → **HTTP/1.1 200 OK**.

**Recommended durable fix (grobase repo):** change the healthcheck URL from `localhost` to
`127.0.0.1` (or bind PostgREST on `::`). Not auto-applied — service is functional; the only defect is
the healthcheck definition.

### 3. `mini-baas-supavisor` reported `unhealthy` — FALSE ALARM (service functional)

**Symptom:** container `unhealthy`; healthcheck output `/bin/sh: curl: not found`.

**Root cause:** the healthcheck is `curl -sSfL --head ... http://127.0.0.1:4000/api/health`, but the
supavisor image ships **no `curl`** — the check can never succeed regardless of service state.
supavisor is the optional connection-pooler overlay (Track-C).

**Proof of health:** `wget http://127.0.0.1:4000/api/health` (IPv4) inside the container → **HTTP/1.1
204 No Content**; it `LISTEN`s on 4000 (api), 6543 + 5432 (pooler).

**Recommended durable fix (grobase repo):** use a tool present in the image (`wget`/`nc`) in the
healthcheck instead of `curl`. Not auto-applied — service is functional.

---

## Non-errors worth noting

- **Cert system-trust auto-skipped.** The agent shell has no TTY, so the system-CA trust step took its
  non-interactive branch (`infrastructure/makes/certs.mk`): `[certs] system CA trust skipped
  (non-interactive) — run once: sudo make certs-trust-local`. This does **not** affect functional
  health (the healthcheck uses `curl --cacert` explicitly). It only governs **browser-green** HTTPS.
  → **One human step remains:** `sudo make certs-trust-local` to trust the local CA in the system /
  browser stores (the single sudo the agent can't perform).
- **`rm: cannot remove '/tmp/finance.bak': Operation not permitted`** during the MSSQL restore — a
  benign cleanup line (the `.bak` is owned by the `mssql` container user); the restore itself
  **succeeded** (`finance` = 5 tables, verified above).

---

## Handoff / remaining manual steps

1. **Browser-green HTTPS (optional, one sudo):** `sudo make certs-trust-local`
2. **Durable WAF fix (recommended):** apply fix #1's one-line change in the grobase repo so the WAF
   crash-loop doesn't recur on the next `make certs`/`make all`.
3. **Cosmetic healthcheck fixes (optional):** fixes #2 and #3 to make `docker ps` show fully green;
   both services already work.
