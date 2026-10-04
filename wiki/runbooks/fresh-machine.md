# Fresh machine — from nothing to a verified demo

The pinned bring-up of a release tag on a machine that has never run the stack, and how to
prove it worked. Every command here is run from the repository root.

## Requirements

| Requirement | Detail | Source |
|---|---|---|
| Docker Engine ≥ 25 + Compose v2 | healthchecks use `start_interval`; measured on Docker 29.8.2 | `docker-compose.yml:3`, [README prerequisites](../../README.md#prerequisites) |
| RAM ≥ 8 GB | `make all` peaked at 6.25 GB used on an 8 GB VM; for a VM, `VM_RAM_MB=8192` | [measured runs](#measured-results) |
| Disk ≥ 30 GB free for Docker | images 13.5 GB + build cache 9.5 GB + volumes 1.4 GB, measured 2026-10-01 | [README prerequisites](../../README.md#prerequisites) |
| Free ports | 443, 3001–3003, 3007, 4000, 4100, 4200, 4322, 4323, 7880, 7881, 8444, 8787, UDP 50000–50060, and Kong on 8000 | `docker-compose.yml`, `apps/grobase/orchestrators/compose/base/gateway.yml` |
| One `sudo` prompt | `make all` copies the local CA into the system store once (`certs-trust-local`) | `infrastructure/makes/certs.mk:23-50` |
| A GitHub SSH key | submodules use `git@github.com:` URLs | `.gitmodules` |

`scripts/verify/fresh-bringup.sh` checks Docker, GitHub SSH and the ports before it builds,
and warns on RAM under 7.5 GiB (an 8 GB VM reports ~7.8 GiB) or under 10 GiB free on the
Docker data root.

## Case A — browser on the same machine

```bash
git clone --recursive git@github.com:Univers42/groot.git && cd groot
git checkout "$(git describe --tags --abbrev=0 origin/main)"
git submodule update --init --recursive
make all SKIP_SYNC=1
```

`make all` trusts the CA in the system store and, when `certutil` is installed, in every NSS
database it finds (Chrome `~/.pki/nssdb`, Firefox profiles) — `infrastructure/makes/certs.mk:43-50`.
Nothing else to do.

## Case B — stack in a born2root VM, browser on the host

1. **Build the VM** with enough RAM and disk (from `vendor/born2root`):
   `make all VM_RAM_MB=8192 VM_SIZE=50` — both variables are documented in
   `vendor/born2root/Makefile:98-120,263`. SSH listens on port 4242
   (`vendor/born2root/born2root.toml:197`).
2. **The VM's login shell is hellish**, not bash. Run every script as `bash scripts/...` and
   wrap one-liners over ssh: `ssh -p 4242 <user>@127.0.0.1 "bash -c 'cd ~/groot && make demo-login'"`.
3. **Bring the stack up inside the VM** exactly as in case A.
4. **Tunnel the loopback-bound ports.** The stack binds every app on the guest's `127.0.0.1`,
   which a QEMU NAT forward cannot reach (`vendor/born2root/setup/host/groot_host_access.sh:8-26`);
   the Whiteboard port is loopback even in NAT mode (`docker-compose.yml:32`). An SSH local
   forward reaches it:

   ```bash
   ssh -p 4242 -N -L 3007:127.0.0.1:3007 <user>@127.0.0.1
   ```

   Add one `-L <port>:127.0.0.1:<port>` per app you open (4322, 3001, 8787, …).
   `make groot` in born2root sets up the whole map plus the CA for you.
5. **Import the CA on the host, checking the fingerprint.** In the VM:

   ```bash
   make certs-export            # DEST=<path> to change the destination
   ```

   It copies `apps/grobase/certs/track-binocle-local-ca.pem` to `./track-binocle-local-ca.pem`,
   prints its SHA-256 fingerprint and the host-side commands: `scp` it out, compare the
   fingerprint, delete every old `Track Binocle Local CA` / `Track Binocle Local Development CA`
   from the Chrome and Firefox NSS stores, import the new one (`scripts/certs-export.sh`). No sudo.
6. **Every VM rebuild is a new CA.** `make certs` on a fresh tree mints a new CA, and a host
   that still trusts the previous one warns exactly as if nothing were imported
   (`vendor/born2root/setup/host/groot_host_access.sh:28-37`). Re-run step 5 after every rebuild.

## Verify the bring-up

```bash
bash scripts/verify/fresh-bringup.sh                    # verify this checkout at the latest tag
bash scripts/verify/fresh-bringup.sh v1.0.0-rc3         # a given tag
bash scripts/verify/fresh-bringup.sh --clone ~/groot-fresh   # clone first
bash scripts/verify/fresh-bringup.sh --with-optional    # also mail-up/calendar-up so DW10 runs
```

It runs preflight → checkout → `git submodule update --init --recursive` → `make all SKIP_SYNC=1`
→ `make healthcheck` → `make e2e` → submodule drift check, and writes every log to
`~/fresh-bringup-logs/<tag>-<time>/` (`--out DIR` to change). Exit status is non-zero if any
check fails. It checks out the tag in the checkout you run it from.

### Reading SUMMARY.txt

```
tag=v1.0.0-rc3 make_all=0 secs=33 healthcheck=0 e2e=0 drift=0 dlesieur_images=0 peak_used_MiB=3342
```

| Field | Pass | Meaning |
|---|---|---|
| `make_all`, `healthcheck`, `e2e` | `0` | exit status of each make target; the log of each is next to it |
| `drift` | `0` | `git submodule status --recursive` unchanged by the bring-up (`drift.diff`) |
| `dlesieur_images` | `0` | number of `dlesieur/*` images present — everything was built locally |
| `mail_up`, `calendar_up` | `0` | only with `--with-optional` |
| `secs` | — | wall time of `make all` |
| `peak_used_MiB` | — | highest `free -m` "used" sample, every 10 s (a shorter spike is missed) |

`e2e` passing with Mail and Calendar down means DW10 was **skipped**, and `e2e.log` says so
(`[DW10 SKIP] …`). Use `--with-optional` for a run that covers it.

## Manual demo checklist

1. `make demo-login` prints the local demo account's email and password
   (`infrastructure/makes/repo.mk:180`). The password exists only in `./.env.local`.
2. Window 1: `https://localhost:4322` → Sign in → continue to osionos.
3. In osionos: **View → Whiteboard** → **+ New Board** → give it a title.
4. Window 2 (a second browser window, same board URL): draw — the strokes appear in window 1.
   The e2e smoke asserts this within 5 s (`tests/e2e/specs/dw8-realtime.spec.ts`).
5. **Do not click Share.** Board editing has no per-user authorization yet; drawnosaurus is
   bound to `127.0.0.1:3007` for that reason (`docker-compose.yml:735`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make healthcheck` / `make e2e` gets **401** | run from a different checkout than the one running the stack: its `.env.local` keys do not match the running Kong (`scripts/gen-local-env.sh:19-24`) | run every `make` from the checkout that ran `make all` |
| Whiteboard tab blank, or `ERR_CERT_AUTHORITY_INVALID` | the browser does not trust the **current** CA; the `:3007` iframe is refused silently | case A: `make certs-trust`; case B: redo `make certs-export` and compare fingerprints |
| Landing looks stale after an update | browser cache. The landing registers no service worker; osionos does (`apps/osionos/app/src/widgets/notifications/model/usePushSubscription.ts`) | hard reload; DevTools → Application → Service workers → Unregister, then Clear site data |
| `/var` full during the build | BuildKit cache | `make docker_reclaim_cache` (`docker builder prune -a -f`, `infrastructure/makes/docker.mk:58-61`) |
| Ports already in use on the **host** while a VM runs | born2root's QEMU forwards 3001–3003, 4000, 4322, 8000, 8787, … to the VM (`vendor/born2root/setup/host/qemu_vm.sh:171`) | stop the VM or the host stack — they cannot share the ports |
| `time: command not found` in the VM | `time` is a bash keyword; hellish has none | `bash -c 'time make all SKIP_SYNC=1'` |
| First VM boot hangs on downloads | QEMU slirp IPv6 had no route | fixed in born2root `07c0971` + `40b2362` (branch `fix/first-boot-network-and-ordering`; groot's submodule pin `7e218df` predates it) |

The full host-trust walkthrough for every browser and OS is
[`archive/wiki-2026-09/troubleshoot/trust-ca-from-host.md`](../../archive/wiki-2026-09/troubleshoot/trust-ca-from-host.md).

## Measured results

| Run | Machine | `make all` | Peak RAM used | Result |
|---|---|---|---|---|
| v1.0.0-rc2, cold clone | old VM, 8 GB | 594 s | ~3.5 GB | pass |
| v1.0.0-rc3, cold clone | old VM, 8 GB | 547 s | ~3.5 GB | pass |
| v1.0.0-rc3, cold clone | vjan-nie42, 8 GB (`~/rehearsal-logs-v1.0.0-rc3/SUMMARY.txt`) | 437 s | 6253 MiB | all checks 0 |
| VM first boot | new VM built with the born2root IPv6 fix | 6 m 15 s | — | then rc3 pass + manual demo |
| v1.0.0-rc3, warm, `fresh-bringup.sh` default mode, 2026-10-04 | vjan-nie42, 8 GB | 33 s | 3342 MiB | all checks 0; DW10 skipped |
