# 0047. With vault42 set, make all deploys the frontends here against the data center VM, and groot starts no grobase

- Status: accepted with conditions (devil, PROCEED-WITH-CONDITIONS, 2026-11-04; the owner replaced condition 1)
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
- **groot starts no grobase on this path.** A VM that does not answer stops `make all` with the repair,
  and `backend-up` refuses. Falling back would build the second grobase this exists to prevent.
- **Runtime traffic crosses to the VM on verified TLS only.** The link stays in direct mode with the
  URL `https://localhost:8443`, and `GROBASE_CONNECT_IP` makes the relay dial the host's address while the
  certificate is still checked for `localhost`. Redis and Mailpit are the link's local stand-ins.
  `GROBASE_ADMIN_SSH` is for bring-up only: the VM's own `.env`, its docker socket, tenant-control.
- **Steps, in order:** sync submodules; pull the vault if a required file is missing; restore the CA
  certificate and edge leaf; check the VM and write the link's settings; link; check the VM read-only and
  apply only what that allows; set the demo password without force; prove the CA signs the WAF and import
  it in every browser store; build and start the frontends; health check; relaunch the browsers.

## What "HTTPS" means here

TLS covers the hop leaving Docker, relay to WAF, and the browser's hop to the edge. The hops inside this
machine's Docker network stay `http://mini-baas-kong:8000`: container to relay, and nginx to relay. They never
leave the host, so rewriting those literals and teaching every Node and Go service the CA would buy no
protection on any wire. This is the reading devil accepted and the one the owner is asked to confirm. It
is not "every hop is HTTPS".

## Conditions

1. Opt-in by an explicit setting outside the checkout. **Replaced by the owner:** credentials are the
   setting ("with the condition of vault42 set"). They are outside the checkout, so CI and a clean
   machine are unchanged, which was the condition's reason.
2. `./.env.grobase-link` is left alone, because a team push publishes it. The settings go to
   `./.env.grobase-link.local` and the VM's secrets to `./.env.grobase-datacenter.local`: `*.local` is
   private to the pusher.
3. The vault is pulled only when a required file is missing, or with `VAULT42_REFRESH=1`. Both push paths
   now keep `*.bak*` private: `*.bak` missed `.bak-<stamp>`, so a backup of `.env.local` would go out shared.
4. The CA key is not restored here, and `make certs` verifies a tree without it instead of calling the
   generator, which deletes such a CA and mints another. This CA has no name constraints and runs to
   2036, so its key could impersonate any site in a browser that trusts it.
5. The trust gate is anchored on the WAF, because `certs-trust-user.sh --check` compares stores to the
   local file. A browser installed with no profile fails the build.
6. VM writes: models and key checks run first (ADR 0003). Armed triggers alone run `realtime-cdc-off`,
   since they return after every grobase `up`. Pending DDL stops unless `DATACENTER_MIGRATE=1`, which
   dumps postgres and verifies the dump first. A key that does not verify always stops: `make all` never
   issues one.
7. Browsers restart last, only if a store changed and stdin is a terminal. The Update button's `make all`
   has none, because a restart would close the tab that asked.
8. Admin ssh drops the alias's forwards and accepts only the pinned host key. A docker `ssh://` transport
   would inherit both, so the docker socket is forwarded on the pinned master.
9. Proof: a real fresh clone, Firefox on a copy of its real store, a store without the CA failing first,
   and a page saved and reloaded through the WAF.

## Alternatives considered

- **Detect the VM from the ssh alias.** Rejected by devil: it changes `make all` for any teammate with a
  VM. The owner's trigger is the credential file.
- **ssh mode with TLS inside the tunnel.** Keeps Redis and realtime on ssh and ties the running stack to
  one ssh master. A direct link has no ssh at runtime.
- **HTTPS on every literal URL.** Larger blast for no protection on any wire (above).

## Consequences

- The first host key is pinned on first use, trusted because the loopback listener is this user's own
  qemu. A rebuilt VM has a new key, and the link says which line to remove.
- Sessions and captured mail live on this machine, in the stand-ins, as on every direct link.
- All bridge traffic meets the WAF from one client address, as on the Funnel path. Do not add that address
  to the operator list: every campus peer arrives the same way through the `0.0.0.0:8443` forward.
- The models check sees missing tables only, so a migration that adds a column needs
  `DATACENTER_MIGRATE=1`.
