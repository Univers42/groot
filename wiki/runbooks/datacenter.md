# Data center — make all with vault42 set

On a machine with vault42 credentials, `make all` builds and starts the frontends here and uses the
grobase in the VM on this host. groot starts no grobase. The decision and its conditions are
[ADR 0047](../../docs/adr/0047-with-vault42-set-make-all-deploys-against-the-data-center-vm.md).

## What you need

| What | Where |
|---|---|
| vault42 credentials and keystore | `~/.config/42ctl/secrets/*.env` (`FT_PASSPHRASE`, `FT_PASSWORD`, `FT_EMAIL`, `FT_TENANT`), `~/.config/42ctl/keystore.v42` or `FT_KEYSTORE_B64` |
| A terminal, the first time | Only to build the VM: about 30 min and 18 GB free under `[vm] path`, with `/dev/kvm` writable |
| A GitHub ssh key | For `git clone --recursive` |

Then:

```sh
git clone --recursive git@github.com:Univers42/groot.git
cd groot
make all
```

No sudo and no prompt. Without credentials `make all` is the local pipeline, unchanged. With some
credentials but not all, it stops and names the missing ones.

## What runs

| Step | Target | Stops when |
|---|---|---|
| Prove the vault can be read | `datacenter-gate` | a credential is missing, or the vault refuses and `./.env.local` and `apps/grobase/.env` are not set by hand |
| Sync submodules | `sync-submodules-soft` | never; `vendor/born2root` stays at its gitlink |
| Pull the vault's tree | `datacenter-secrets` | the vault refuses; skipped when the files are here |
| Build an absent VM, wait for it, repair grobase, seed an empty platform | `datacenter-vm` | see below |
| Pin the host key, write `./.env.grobase-link.local` | `datacenter-configure` | a target that is not this user's own VM has no pin |
| Copy the CA and the WAF's leaf from the VM | `datacenter-certs` | the leaf does not chain, or the key is not its own |
| Open the link, derive `./.env.local` | `link` | the WAF does not answer from a container |
| Converge models and the key | `datacenter-preflight` | the dump does not read back, or the key does not verify |
| Write the agency roster from the VM's accounts | `datacenter-roster` | the VM lacks an account |
| Demo password, without force | `link-demo-login-ensure` | |
| Prove the CA, import it in the browsers | `datacenter-trust` | the CA does not verify the WAF, or a store still lacks it |
| Build and start the frontends | `link-frontends-start` | a build fails, or the link does not verify |
| Start Mail and Calendar | `datacenter-apps` | a build fails |
| Health checks | `link-healthcheck`, `datacenter-health` | a probe fails |
| Prove the plan, pages, bind mounts and browsers | `datacenter-verify` | any of them fails, or a browser test skips |
| URLs | `showcase` | never |
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

## What the VM runs

Every grobase service that is not retired: 44 running plus 6 one-shots, measured on 2026-11-05. That is
`max` plus `LOCAL_GROBASE_ADDONS` in `scripts/lib/datacenter-vm.sh`, on this machine's VM only. grobase's
`max` and born2root's server profile stay what production deploys. A build drops cloudflared, and
Tailscale is off in the profile, so nothing here touches the tailnet or Cloudflare.

## Settings

| Setting | Where | Effect |
|---|---|---|
| `GROBASE_DATACENTER=<alias>` | a credential file | Another alias than `b2b` |
| `GROBASE_DATACENTER=local` | a credential file | This machine has no data center |
| `make all GROBASE_DATACENTER=`, or `=local` | one run | The local pipeline |
| `VAULT42_REFRESH=1` | one run | Pull the vault even though the files are here |
| `DATACENTER_ALLOW_WRITES=1` | one run | Allow VM writes with no terminal; never a VM build |
| `DATACENTER_VERIFY_BROWSERS=1` | one run | Run the browsers with no terminal |
| `GROOT_NO_BROWSER_RESTART=1` | one run | Say relaunch instead of doing it |
| `GROBASE_CONNECT_IP=<ip>` | a credential file | The address the relay dials, when the default route's is wrong |

`~/.config/42ctl/secrets/datacenter.env` holds the pinned host key. Database dumps go to
`~/.local/state/groot/datacenter-dumps`, mode 700.

## Repairs

| Message | Cause | Repair |
|---|---|---|
| `Stopped on purpose` | `make qemu_stop` left a hold | From born2root: `make qemu_start B2B_CONFIG=profiles/server.toml` |
| `run make all at a terminal` | This machine has no VM, and a build needs someone there | `make all` in a terminal |
| `not provably absent` | The disk cannot be read, a VM port is taken, or the alias is not `b2b` | Read the path; log in if the NFS ticket expired |
| `no .installed mark` | An install was interrupted | Read the directory, then from born2root: `make all B2B_CONFIG=profiles/server.toml` |
| `a backup repository exists` | Seeds are older than it | Build from born2root, then `make restore`, or move it away |
| `/dev/kvm is not writable` | Nobody holds this seat's session | Log in at the seat |
| `has no make <target>` | groot's born2root pin is behind | Move the pin |
| `holds N tenants and no record of a seed` | Rows of unknown origin | If they are expendable, from born2root: `make set_seeds FORCE=1` |
| `the VM has no account for` | Its seed lacks the agency people, so people lists would be empty | From born2root: `make set_seeds` |
| `the VM is still not converged` | A long reader kept a table past the 2 s lock budget, such as an hourly backup | `make all` again |
| `the app's key or the rows it owns need a repair` | They drifted after this seed was converged | Read ADR 0003, then `make link-live-data-ensure` |
| `Firefox is installed but has no profile` | It never started | Start it once, then `make all` |

## What it does not do

- It does not keep the VM up. On a school seat it stops about 24 h after the last password typed there,
  and after a host reboot it waits for a login ([ADR 0047](../../docs/adr/0047-with-vault42-set-make-all-deploys-against-the-data-center-vm.md)).
- It does not start the VM, and it builds one only when it provably does not exist.
- It does not run the `pr*` mail specs: `tests/e2e/run.sh` refuses them on a remote backend, so test users do not land on the VM. `make e2e` says so in its log.
- It does not run the `st*` site specs, which target a redesign that is on no branch.
- It does not put every hop on TLS: containers reach the relay in plain HTTP on this machine's Docker
  network. TLS covers the hop leaving Docker and the browser's hop to the edge.
- It does not give Mail and Calendar a Google sign-in: no Google client is set for them. They open and embed in osionos, which is what `datacenter-verify` and the DW10 spec prove.
