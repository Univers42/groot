# Fresh machine — from nothing to a verified demo

The pinned bring-up of a release tag on a machine that has never run the stack, and how to
prove it worked. Every command here is run from the repository root unless a step says
otherwise.

## Requirements

| Requirement | Detail | Source |
|---|---|---|
| Docker Engine ≥ 25 + Compose v2 | healthchecks use `start_interval`; measured on Docker 29.8.2 | `docker-compose.yml:3`, [README prerequisites](../../README.md#prerequisites) |
| RAM ≥ 8 GB | `make all` peaked at 6.25 GB used on an 8 GB VM; for a VM, `VM_RAM_MB=8192` | [measured runs](#measured-results) |
| Disk ≥ 30 GB free for Docker | images 13.5 GB + build cache 9.5 GB + volumes 1.4 GB, measured 2026-10-01 | [README prerequisites](../../README.md#prerequisites) |
| Free ports | 443, 3001–3003, 3007, 4000, 4100, 4200, 4322, 4323, 7880, 7881, 8444, 8787, UDP 50000–50060, and Kong on 8000 | `docker-compose.yml`, `apps/grobase/orchestrators/compose/base/gateway.yml` |
| One `sudo` password | `make all` copies the local CA into the system store once (`certs-trust-local`); `fresh-bringup.sh` asks for it first, with `sudo -v` | `infrastructure/makes/certs.mk:22-51`, `scripts/verify/fresh-bringup.sh` (`check_sudo`) |
| A GitHub SSH key | submodules use `git@github.com:` URLs | `.gitmodules` |

`scripts/verify/fresh-bringup.sh` checks sudo, Docker, GitHub SSH and the ports before it
builds, and warns on RAM under 7.5 GiB (an 8 GB VM reports ~7.8 GiB) or under 10 GiB free on
the Docker data root.

## Bring up — one path: `fresh-bringup.sh`

On the machine that will run the stack (the VM in case B):

```bash
git clone git@github.com:Univers42/groot.git ~/groot && cd ~/groot
bash scripts/verify/fresh-bringup.sh
```

The script is the bring-up, not a check run after it: preflight → checkout of the latest tag
on `origin/main` → `git submodule update --init --recursive` → `make all SKIP_SYNC=1` →
`make healthcheck` → `make e2e` → submodule drift check. **Do not also run `git checkout`,
`make all` or any other bring-up command by hand** — it would repeat the build the script
already did and verified.

- Clone into `~/groot`: born2root's `make groot` reads the guest's checkout from there
  (`vendor/born2root/setup/host/groot_host_access.sh:65`).
- The first thing it does is `sudo -v`, so the one password prompt comes before the build and
  the cached credential covers `make all`'s CA step. Tags up to v1.0.0-rc4 predate that
  preflight: run `sudo -v` yourself just before the script.
- On the VM, call it from bash (step B2): `bash -c 'cd ~/groot && bash scripts/verify/fresh-bringup.sh'`.

```bash
bash scripts/verify/fresh-bringup.sh v1.0.0-rc4         # a given tag
bash scripts/verify/fresh-bringup.sh --clone ~/groot-fresh   # clone into a new directory first
bash scripts/verify/fresh-bringup.sh --with-optional    # also mail-up/calendar-up so DW10 runs
```

Every log goes to `~/fresh-bringup-logs/<tag>-<time>/` (`--out DIR` to change). Exit status is
non-zero if any check fails. Without `--clone` it checks out the tag in the checkout you run it
from.

### Reading SUMMARY.txt

```
tag=v1.0.0-rc4 make_all=0 secs=616 healthcheck=0 e2e=0 drift=0 dlesieur_images=0 peak_used_MiB=6266
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

## Case A — browser on the same machine

Nothing beyond the bring-up. `make all` trusts the CA in the system store and, through
`scripts/certs-trust-user.sh`, in every browser NSS store of this user; relaunch the browser
afterwards. `make certs-trust-check` lists the stores and their state (README, "Access and the
local CA").

## Case B — stack in a born2root VM, browser on the host

**B1. Build the VM** from `vendor/born2root` (pinned at `5c0fb4c`) with the groot profile.
First rename `[users.vjan-nie]` in `infrastructure/vm/born2root-groot.toml` to your own login.

```bash
cd vendor/born2root
cp ../../infrastructure/vm/born2root-groot.toml profiles/groot.toml
make re BACKEND=qemu B2B_CONFIG=profiles/groot.toml SIZE_B2B=91 VM_RAM_MB=8192 PROFILE=minimal FEATURES="+docker +claude-code +nodejs +devtools-extra +nvim-extras +playwright"
make verify_guest B2B_CONFIG=profiles/groot.toml
```

- `make re` is `fclean all`: it **destroys any existing VM** of that name first
  (`vendor/born2root/Makefile:952-957`).
- `SIZE_B2B=91` because `/var` holds Docker and takes what the profile's fixed volumes leave:
  91 GB gave `/var` 65 GB. The old `make all VM_RAM_MB=8192 VM_SIZE=50` leaves `/var` ~21 GB,
  under the ~25 GB the images and build cache need.
- Measured 2026-10-05: 15 m 35 s in total, first boot 7 m 15 s, every feature installed.
- `verify_guest` must get the same `B2B_CONFIG`: it compares the guest against the config's
  hostname and accounts (`vendor/born2root/setup/host/verify_guest_parity.sh:105`), and
  against the default `born2root.toml` it fails. With it: 41/41.
- SSH listens on port 4242 (`vendor/born2root/born2root.toml:14`); `make all` writes the `b2b`
  alias into the host's `~/.ssh/config`, which `make groot` uses (`vendor/born2root/setup/host/groot_host_access.sh:62-63`).

**B2. The VM's login shell is hellish**, not bash. Run every script as `bash scripts/...` and
wrap one-liners over ssh: `ssh -p 4242 <user>@127.0.0.1 "bash -c 'cd ~/groot && make demo-login'"`.

**B3. A GitHub SSH key in the VM.** The VM has none, and the clone and every submodule use SSH:

```bash
ssh-keygen -t ed25519 -C "<login>@groot-vm"
cat ~/.ssh/id_ed25519.pub     # GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com         # check the host key against GitHub's published fingerprints;
                              # it must answer "successfully authenticated"
```

`fresh-bringup.sh` refuses to start until that last command succeeds.

**B4. A git identity in the VM**, for any commit or tag made there:

```bash
git config --global user.name  "<Your Name>"
git config --global user.email "<you@example.com>"
```

**B5. Bring the stack up** with [the script](#bring-up--one-path-fresh-bringupsh), inside the VM.

**B6. Reach the apps from the host.** Which ports need a tunnel depends on how the proxy binds:

- **3007 (Whiteboard)** is published on a literal `127.0.0.1` (`docker-compose.yml:27-32`).
  A QEMU NAT forward reaches the guest's NIC, never its loopback, so 3007 needs an SSH tunnel.
- **3001, 4322, 8787** and the rest of the proxy's ports use `TRACK_BINOCLE_BIND_ADDR`, which is
  `0.0.0.0` inside a QEMU/VirtualBox NAT VM (`infrastructure/scripts/detect-bind-addr.sh:15-16`),
  so born2root's QEMU forwards reach them without a tunnel (`vendor/born2root/setup/host/qemu_vm.sh:171`).
  That binding is open item T14. Once T14 binds them back to `127.0.0.1`, those forwards stop
  working (`vendor/born2root/setup/host/groot_host_access.sh:8-27`) and each port needs its own
  `-L` like 3007. `make groot` asks for every published port, but the dead forwards would still
  hold the host ports: it releases them only when it finds the QEMU monitor socket, which the
  2026-10-05 run did not exercise (it released none).

*Tested route — `make groot`*, on the host, from `vendor/born2root`:

```bash
make groot          # map + tunnel + CA trust + per-port check
make groot_undo     # close the tunnel, remove the CA from the NSS stores
```

What it changes on the host (`vendor/born2root/setup/host/groot_host_access.sh`):

| Change | 2026-10-05 run | Undone by |
|---|---|---|
| Background `ssh -f -N -L <port>:127.0.0.1:<port> … b2b` for every port the proxy publishes; pid in `~/.local/share/born2root/groot-tunnel.pid` | `✓ SSH tunnel up (pid 686674)`, 10 ports mapped | `make groot_undo` |
| The guest's CA copied to `~/.local/share/born2root/track-binocle-local-ca.pem` | `✓ CA fetched: 30:57:55:81:BE:EB:E5:67…` | stays; overwritten next run |
| In every NSS store found: delete `Track Binocle Local CA` and `Track Binocle Local Development CA`, import the new CA as `Track Binocle Local CA` | `✓ CA trusted in 2 NSS store(s)` | `make groot_undo` |
| QEMU forwards on those ports released through the monitor socket, only when QEMU holds them on `127.0.0.1` | no `released … QEMU forward(s)` line: none released | next `make qemu_start` |
| `certutil` unpacked into `~/.cache/born2root/nss` only when none is installed | — | stays |

The tunnel uses `ExitOnForwardFailure=no`, so a `-L` whose host port a QEMU forward already
holds does not bind and that port keeps going through the forward. In this run that is every
port except 3007 and 8444, which QEMU does not forward (`vendor/born2root/setup/host/qemu_vm.sh:171`).
The per-port check then passed on all 10: 200 on 4322, 3001, 8444, 3007; 404 on the 4000 and
8787 roots; 502 on 3002, 4100, 3003, 4200 because Mail and Calendar are optional and were not
started. A `✓` there means TLS verified against the CA, not that the app is up.

Restart the browser completely afterwards: NSS is read at startup.

*Manual route — tunnel + `certs-export`*:

```bash
ssh -p 4242 -N -L 3007:127.0.0.1:3007 <user>@127.0.0.1      # on the host
make certs-export                                            # in the VM; DEST=<path> to change it
```

`certs-export` copies `apps/grobase/certs/track-binocle-local-ca.pem` to
`./track-binocle-local-ca.pem`, prints its SHA-256 fingerprint and subject, and prints the
host-side commands: `scp` it out, compare the fingerprint, then, per Chrome and Firefox NSS
store, offer to remove every certificate with the **same subject** whatever nickname it was
imported under, and import the new one (`scripts/certs-export.sh`). No sudo. It searches
`~/.pki/nssdb` and the classic and snap Firefox profiles, not snap Chromium or flatpak Firefox.

**B7. Every VM rebuild is a new CA.** `make certs` on a fresh tree mints a new CA, and a host
that still trusts the previous one warns exactly as if nothing were imported
(`vendor/born2root/setup/host/groot_host_access.sh:29-37`). Re-run B6 after every rebuild.

## Manual demo checklist

1. `make demo-login` prints the local demo account's email and password
   (`infrastructure/makes/repo.mk:180-182`). The password exists only in `./.env.local`.
2. Window 1: `https://localhost:4322` → Sign in → continue to osionos.
3. In osionos: **View → Whiteboard** → **+ New Board** → give it a title.
4. Window 2 — an **incognito window or another browser profile**, not a second window of the
   same session: sign in with the same `make demo-login` credentials, open the same board URL,
   draw — the strokes appear in window 1. The e2e smoke asserts this within 5 s
   (`tests/e2e/specs/dw8-realtime.spec.ts`).
5. **Do not click Share.** Board editing has no per-user authorization yet; drawnosaurus is
   bound to `127.0.0.1:3007` for that reason (`docker-compose.yml:27-32`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make healthcheck` / `make e2e` gets **401** | run from a different checkout than the one running the stack: its `.env.local` keys do not match the running Kong (`scripts/gen-local-env.sh:19-24`) | run every `make` from the checkout that ran `make all` |
| Whiteboard tab blank, or `ERR_CERT_AUTHORITY_INVALID` | the browser does not trust the **current** CA; the `:3007` iframe is refused silently | case A: `make certs-trust`; case B: re-run `make groot`, or redo `make certs-export` and compare fingerprints |
| Landing looks stale after an update | browser cache. The landing registers no service worker; osionos does (`apps/osionos/app/src/widgets/notifications/model/usePushSubscription.ts`) | hard reload; DevTools → Application → Service workers → Unregister, then Clear site data |
| `/var` full during the build | BuildKit cache | `make docker_reclaim_cache` (`docker builder prune -a -f`, `infrastructure/makes/docker.mk:58-61`) |
| Ports already in use on the **host** while a VM runs | born2root's QEMU forwards 3001–3003, 4000, 4322, 8000, 8787, … to the VM (`vendor/born2root/setup/host/qemu_vm.sh:171`) | stop the VM or the host stack — they cannot share the ports |
| `time: command not found` in the VM | `time` is a bash keyword; hellish has none | `bash -c 'time make all SKIP_SYNC=1'` |
| `make verify_guest` fails on hostname / user | it compared the guest against the default `born2root.toml` | pass the build's config: `make verify_guest B2B_CONFIG=profiles/groot.toml` |
| First VM boot hangs on downloads | QEMU slirp IPv6 had no route | fixed in born2root `5c0fb4c` (born2root PRs #11, #12), pinned in groot by #59; rebuild the VM from that pin |

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
| VM build, [B1](#case-b--stack-in-a-born2root-vm-browser-on-the-host) recipe, 2026-10-05 | born2root `5c0fb4c`, QEMU, 8 GB, 91 GB disk | — | — | 15 m 35 s total, first boot 7 m 15 s; `/var` 65 GB; `verify_guest` 41/41 |
| v1.0.0-rc4, fresh VM, `fresh-bringup.sh` default mode, 2026-10-05 | that VM | 616 s | 6266 MiB | all checks 0; DW10 skipped; manual demo pass |

v1.0.0-rc4 was tagged on `main` for that run because v1.0.0-rc3 predates `fresh-bringup.sh`.
