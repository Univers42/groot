# 0047. With vault42 set, make all deploys the frontends here against the data center VM, and groot starts no grobase

- Status: accepted with conditions (devil, PROCEED-WITH-CONDITIONS twice on 2026-11-04; the owner replaced condition 1 and answered the verdict's questions)
- Date: 2026-11-04
- Deciders: the owner (the request and the vault42 trigger); devil (the conditions). The operator of the VM lives with it.

## Context

- The owner asked for one command from a fresh clone: `make all` fetches every secret from vault42 with
  `~/.config/42ctl/secrets/42admin.env`, connects to the VM on this machine that is the data center of
  its localhost domain, and compiles and deploys here. Backend and frontend talk over HTTPS, not over the
  tailnet. Firefox and Chrome open every URL with no warning, done as born2root did for Inception. The
  owner added that groot must never start grobase, since `apps/grobase` is legacy here.
- `make all` was the local pipeline: its `backend-up` builds a second grobase. `make link-all` pulled the
  vault and linked, but left the target to `./.env.grobase-link`, and the vault delivers that file with
  the tailnet target.
- Direct mode, the only link that speaks TLS to the WAF, could not fetch secrets and refused migrations
  (ADR 0003). `./.env.grobase-remote` from the vault did not match the VM, so `gen-local-env.sh --sync`
  would have replaced good keys with ones the VM refuses.
- All five browser stores on the seat held a stale CA. That was the cause of the warnings.
- The seat has no sudo and rootless Docker: a container cannot reach the host's loopback, and
  `host.docker.internal` is refused. A container does reach the VM's forward on the host's own address.

## Decision

- **vault42 credentials are the switch.** `scripts/datacenter.sh setting` reads the credential files
  `scripts/lib/vault42-session.sh` reads. A passphrase plus a keystore means this machine has a data
  center, by default the alias `b2b`. `GROBASE_DATACENTER=<alias>` in those files names another,
  `GROBASE_DATACENTER=local` opts out, and `make all GROBASE_DATACENTER=` takes the local path for one
  run. A machine without credentials (CI, a clean evaluation machine) runs the pipeline it always ran.
- **grobase runs only in the VM, and groot drives it.** Delivered groot is the only thing a user holds,
  so `make all` decides by state. groot never starts or builds the VM: autostart keeps it up, and
  `BAAS_LUKS_PASSPHRASE` stays out of the vault.

  | State after the wait | groot does |
  |---|---|
  | The VM is held, has no disk, no auto-start, or `/dev/kvm` is not writable | Stops at once and names it |
  | The VM is booting | Waits: 180 s for QEMU, 300 s for ssh, 300 s for the WAF |
  | grobase running | Uses it |
  | grobase stopped or absent | born2root's `make grobase`, then re-reads the state |
  | Platform empty | born2root's `make set_seeds`, unforced, so credentials never enter the guest |
  | Rows and no `/etc/b2b/seeds.last` | Stops, naming `make set_seeds FORCE=1` |

  `make up` in `/opt/grobase` is never used: it starts the default edition and its `_rm-stale` can
  remove containers. `make dc-<target>` allows `ps`, `logs` and `health`, sends `up` through born2root,
  and refuses the rest. `vendor/born2root` stays at its gitlink, so what runs is what was tested, and a
  pin without a needed target stops with the commit named.
- **Runtime traffic crosses to the VM on verified TLS only.** The link stays in direct mode with the
  URL `https://localhost:8443`, and `GROBASE_CONNECT_IP` makes the relay dial the host's address while the
  certificate is still checked for `localhost`. Redis and Mailpit are the link's local stand-ins.
  `GROBASE_ADMIN_SSH` is for bring-up only: the VM's own `.env`, its docker socket, tenant-control.
- **Steps, in order:** sync submodules; pull the vault if a required file is missing; bring the VM to
  the state above; pin its host key and write the link's settings; copy its certificates; link; converge
  models and the key; set the demo password without force; prove the CA signs the WAF and import it in
  every browser store; build and start the frontends and Mail and Calendar; health check; born2root's
  `make health`; relaunch the browsers.

## What "HTTPS" means here

TLS covers the hop leaving Docker, relay to WAF, and the browser's hop to the edge. The hops inside this
machine's Docker network stay `http://mini-baas-kong:8000`: container to relay, and nginx to relay. They never
leave the host, so rewriting those literals and teaching every Node and Go service the CA would buy no
protection on any wire. This is the reading devil accepted and the one the owner is asked to confirm. It
is not "every hop is HTTPS".

## Conditions

1. Opt-in by an explicit setting outside the checkout. **Replaced by the owner:** credentials are the
   setting ("with the condition of vault42 set"). They are outside the checkout, so CI and a clean
   machine are unchanged, which was the condition's reason. A keystore carried in the credentials file
   counts, so such a seat cannot fall to the local path.
2. `./.env.grobase-link` is left alone, because a team push publishes it. The settings go to
   `./.env.grobase-link.local` and the VM's secrets to `./.env.grobase-datacenter.local`: `*.local` is
   private to the pusher.
3. The vault is pulled only when a required file is missing, or with `VAULT42_REFRESH=1`. Both push paths
   keep `*.bak*` private: `*.bak` missed `.bak-<stamp>`, so a backup of `.env.local` would go out shared.
4. Certificates come from the VM on every run, after the host key is pinned: the CA certificate from
   `/opt/grobase/certs`, the leaf and its key as the WAF holds them, because the key is root's on the VM.
   The set is checked for chain and key match before any file moves. The CA key is never copied, and
   `make certs` verifies a tree without it instead of calling the generator, which deletes such a CA and
   mints another. This CA has no name constraints and runs to 2036, so its key could impersonate any site.
5. The trust gate is anchored on the WAF, because `certs-trust-user.sh --check` compares stores to the
   local file. A browser installed with no profile fails the build.
6. VM writes need a terminal, or `DATACENTER_ALLOW_WRITES=1`: `POST /rebuild`, the Update button, is
   unauthenticated with CORS `*`. Models apply, by the owner's decision, after a dump read back in full,
   and a hash of `models/*.sql` kept in `groot_meta.models_state` catches a column-only change. Armed
   triggers run `realtime-cdc-off` alone. A key or row owner that needs a repair converges once per
   seed recorded in `/etc/b2b/seeds.last`, whoever loaded it, by the owner's decision: until
   `groot_meta.seed_state` holds that seed the rows are known to be the seed's. After that a mismatch
   stops, so rows users added are never re-stamped. The re-stamp writes five databases the dump does
   not cover; a new seed restores them.
7. Browsers restart last, only if a store changed and stdin is a terminal.
8. Admin ssh drops the alias's forwards and accepts only the pinned host key. For this user's own VM the
   key is re-read every run, so a rebuild needs nothing; any other target keeps a strict pin. born2root
   is called with MAKEFLAGS cleared.
9. Proof: a real fresh clone, Firefox on a copy of its real store, a store without the CA failing first,
   and a page saved and reloaded through the WAF.
10. Landing order: grobase, then born2root with `grobase_ref` pinned to the tested commit, then groot's
    pin with this work. The health gate ships with born2root's commit.

## Alternatives considered

- **Detect the VM from the ssh alias.** Rejected by devil: it changes `make all` for any teammate with a
  VM. The owner's trigger is the credential file.
- **ssh mode with TLS inside the tunnel.** Keeps Redis and realtime on ssh and ties the running stack to
  one ssh master. A direct link has no ssh at runtime.
- **HTTPS on every literal URL.** Larger blast for no protection on any wire (above).

## Consequences

- A school seat cannot give "always on". Without root there is no linger, `/dev/kvm` is granted per
  login, and the disk is on `sec=krb5` NFS, so the VM is powered off about 24 h after the last password
  on that seat, and after a host reboot it starts within a minute of the next login. `make all` right
  after a login waits for it.
- Sessions and captured mail live on this machine, in the stand-ins, as on every direct link.
- All bridge traffic meets the WAF from one client address, as on the Funnel path. Do not add that address
  to the operator list: every campus peer arrives the same way through the `0.0.0.0:8443` forward.
- The realtime triggers come back on every grobase `up` (`012_realtime_triggers_all_tables.sql`). A run
  clears them from a terminal; the lasting fix is in grobase.
