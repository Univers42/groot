# Data center — make all with vault42 set

On a machine with vault42 credentials, `make all` builds and starts the frontends here and uses the
grobase in the VM on this host. groot starts no grobase. The decision and its conditions are
[ADR 0047](../../docs/adr/0047-with-vault42-set-make-all-deploys-against-the-data-center-vm.md).

## What you need

| What | Where |
|---|---|
| vault42 credentials and keystore | `~/.config/42ctl/secrets/*.env` (`FT_PASSPHRASE`, `FT_PASSWORD`, `FT_EMAIL`, `FT_TENANT`), `~/.config/42ctl/keystore.v42` |
| The VM, running grobase | ssh alias `b2b`, written by born2root; its WAF forwarded on `:8443` |
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
| Sync submodules | `sync-submodules-soft` | never |
| Pull the vault's tree | `datacenter-secrets` | the vault refuses; skipped when the files are here |
| Restore the CA certificate and edge leaf | `datacenter-certs` | the leaf does not chain to the CA |
| Check the VM, pin its host key, write `./.env.grobase-link.local` | `datacenter-configure` | the VM or its WAF does not answer |
| Open the link, derive `./.env.local` | `link` | the WAF does not answer from a container |
| Check the VM | `datacenter-preflight` | pending DDL, or the app's key does not verify |
| Demo password, without force | `link-demo-login-ensure` | |
| Prove the CA, import it in the browsers | `datacenter-trust` | the CA does not verify the WAF, or a store still lacks it |
| Build and start the frontends | `link-frontends-start` | a build fails, or the link does not verify |
| Health check, URLs | `link-healthcheck`, `showcase` | a probe fails |
| Relaunch the browsers | `datacenter-browsers` | never |

## Settings

| Setting | Where | Effect |
|---|---|---|
| `GROBASE_DATACENTER=<alias>` | a credential file | Another alias than `b2b` |
| `GROBASE_DATACENTER=local` | a credential file | This machine has no data center |
| `make all GROBASE_DATACENTER=` | one run | The local pipeline |
| `VAULT42_REFRESH=1` | one run | Pull the vault even though the files are here |
| `DATACENTER_MIGRATE=1` | one run | Apply pending models after a verified dump |
| `GROOT_NO_BROWSER_RESTART=1` | one run | Say relaunch instead of doing it |
| `GROBASE_CONNECT_IP=<ip>` | a credential file | The address the relay dials, when the default route's is wrong |

`~/.config/42ctl/secrets/datacenter.env` holds the pinned host key.

## Repairs

| Message | Cause | Repair |
|---|---|---|
| `the data center VM does not answer` | The VM is off or held | Start it from the born2root checkout that built it |
| `no admin ssh` | A rebuilt VM has a new host key | Delete `GROBASE_ADMIN_HOST_KEY` from `datacenter.env`, then `make all` |
| `does not verify https://localhost:8443` | The CA here is not the VM's | `rm -r apps/grobase/certs`, then `VAULT42_REFRESH=1 make all` |
| `models migrations are pending` | The VM is behind `models/` | `make all DATACENTER_MIGRATE=1` |
| `the VM is still not converged` | A long reader held a table past the 2 s lock budget, such as the hourly backup at `:15` | `make all` again |
| `the app's API key does not verify` | `./.env.local` and the VM disagree | Read ADR 0003, then `make link-live-data-ensure` |
| `Firefox is installed but has no profile` | It never started | Start it once, then `make all` |

## What it does not do

- It does not put every hop on TLS: containers reach the relay in plain HTTP on this machine's Docker
  network. TLS covers the hop leaving Docker and the browser's hop to the edge.
- It does not see a migration that only adds a column. After a models change use `DATACENTER_MIGRATE=1`.
- It does not start the VM, or Mail and Calendar (`make mail-up calendar-up`).
- It does not restore data into the VM. born2root seeds it.
