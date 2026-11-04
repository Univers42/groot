# Data center — make all with vault42 set

On a machine with vault42 credentials, `make all` builds and starts the frontends here and uses the
grobase in the VM on this host. groot starts no grobase. The decision and its conditions are
[ADR 0047](../../docs/adr/0047-with-vault42-set-make-all-deploys-against-the-data-center-vm.md).

## What you need

| What | Where |
|---|---|
| vault42 credentials and keystore | `~/.config/42ctl/secrets/*.env` (`FT_PASSPHRASE`, `FT_PASSWORD`, `FT_EMAIL`, `FT_TENANT`), `~/.config/42ctl/keystore.v42` or `FT_KEYSTORE_B64` |
| The VM | ssh alias `b2b` and the auto-start block, both written by born2root |
| A GitHub ssh key | For `git clone --recursive` |

Then:

```sh
git clone --recursive git@github.com:Univers42/groot.git
cd groot
make all
```

No sudo and no prompt. Without credentials `make all` is the local pipeline, unchanged.

## What runs

| Step | Target | Stops when |
|---|---|---|
| Sync submodules | `sync-submodules-soft` | never; `vendor/born2root` stays at its gitlink |
| Pull the vault's tree | `datacenter-secrets` | the vault refuses; skipped when the files are here |
| Wait for the VM, start grobase, seed an empty platform | `datacenter-vm` | see below |
| Pin the host key, write `./.env.grobase-link.local` | `datacenter-configure` | a target that is not this user's own VM has no pin |
| Copy the CA and the WAF's leaf from the VM | `datacenter-certs` | the leaf does not chain, or the key is not its own |
| Open the link, derive `./.env.local` | `link` | the WAF does not answer from a container |
| Converge models and the key | `datacenter-preflight` | the dump does not read back, or the key does not verify |
| Demo password, without force | `link-demo-login-ensure` | |
| Prove the CA, import it in the browsers | `datacenter-trust` | the CA does not verify the WAF, or a store still lacks it |
| Build and start the frontends | `link-frontends-start` | a build fails, or the link does not verify |
| Health checks, URLs | `link-healthcheck`, `datacenter-health`, `showcase` | a probe fails |
| Relaunch the browsers | `datacenter-browsers` | never |

`datacenter-vm` waits up to 180 s for QEMU, 300 s for ssh and 300 s for the WAF, so `make all` right
after a login works while the VM boots. Writes to the VM need a terminal or `DATACENTER_ALLOW_WRITES=1`;
the Update button has neither, so it can rebuild the frontends and never touches the VM.

## Control the VM from groot

| Command | Does |
|---|---|
| `make dc-health` | grobase's health check in the VM |
| `make dc-ps`, `make dc-logs` | Its containers and logs |
| `make dc-up` | Starts grobase through born2root's `make grobase` |

Anything else is refused. Bare `make up` in `/opt/grobase` starts the wrong edition and can remove
containers, so it is never used.

## Settings

| Setting | Where | Effect |
|---|---|---|
| `GROBASE_DATACENTER=<alias>` | a credential file | Another alias than `b2b` |
| `GROBASE_DATACENTER=local` | a credential file | This machine has no data center |
| `make all GROBASE_DATACENTER=` | one run | The local pipeline |
| `VAULT42_REFRESH=1` | one run | Pull the vault even though the files are here |
| `DATACENTER_ALLOW_WRITES=1` | one run | Allow VM writes with no terminal |
| `GROOT_NO_BROWSER_RESTART=1` | one run | Say relaunch instead of doing it |
| `GROBASE_CONNECT_IP=<ip>` | a credential file | The address the relay dials, when the default route's is wrong |

`~/.config/42ctl/secrets/datacenter.env` holds the pinned host key. Database dumps go to
`~/.local/state/groot/datacenter-dumps`, mode 700.

## Repairs

| Message | Cause | Repair |
|---|---|---|
| `Stopped on purpose` | `make qemu_stop` left a hold | From born2root: `make qemu_start B2B_CONFIG=profiles/server.toml` |
| `no VM disk` | This machine has no data center | Build one with born2root; groot does not |
| `no auto-start` | The crontab block is missing | From born2root: `make autostart` |
| `/dev/kvm is not writable` | Nobody holds this seat's session | Log in at the seat |
| `has no make <target>` | groot's born2root pin is behind | Move the pin |
| `holds N tenants and no record of a seed` | Rows of unknown origin | If they are expendable, from born2root: `make set_seeds FORCE=1` |
| `the VM is still not converged` | A long reader kept a table past the 2 s lock budget, such as the hourly backup at `:15` | `make all` again |
| `the app's API key does not verify` | `./.env.local` and the VM disagree | Read ADR 0003, then `make link-live-data-ensure` |
| `Firefox is installed but has no profile` | It never started | Start it once, then `make all` |

## What it does not do

- It does not keep the VM up. On a school seat it stops about 24 h after the last password typed there,
  and after a host reboot it waits for a login ([ADR 0047](../../docs/adr/0047-with-vault42-set-make-all-deploys-against-the-data-center-vm.md)).
- It does not start or build the VM.
- It does not put every hop on TLS: containers reach the relay in plain HTTP on this machine's Docker
  network. TLS covers the hop leaving Docker and the browser's hop to the edge.
- It does not start Mail and Calendar (`make mail-up calendar-up`).
