# Another device: groot and the grobase CLI against the data center, over every network

> **This page is a prompt.** Hand it whole to the AI agent on the other device: it is the
> procedure and the test plan. Do the sections in order, run every row of §9 the device can
> reach, fill in its results table and report as §9 says. The detail behind each step lives in
> [grobase-link](grobase-link.md) and grobase-cli's
> [docs/CONNECTING.md](https://github.com/Univers42/grobase-cli/blob/main/docs/CONNECTING.md);
> this page links to them rather than repeating them.

The data center is the born2root QEMU VM `b2b`, running grobase at `/opt/grobase` on the host
`192.168.1.132`. "Another device" is any machine that is not that host: a laptop on the same
wifi, a 42 seat, a machine on another network. On it you get three things working:

1. **the grobase CLI** (`grobase`), talking to the data center's API edge (the WAF);
2. **the team's secrets**, pulled from vault42;
3. **groot's frontends**, running on the device, reaching the data center's grobase through
   `make link`.

## 0. Rules for the agent

- **Never print a secret value.** That covers passwords, keys, tokens, and any line of an
  `.env` file. Check a secret by name: `grep -q '^NAME=.' FILE && echo "NAME set"`. Pass one
  through a pipe or a `--*-stdin` flag. Never `cat`, `source` or `echo` an env file, and
  never put a secret in a command's arguments.
- **Never turn TLS verification off.** That means no `curl -k`, `--insecure`,
  `--insecure-skip-verify` or `verify=0`. Trust the data center through its CA file or the
  leaf pin (§5), each checked against the value printed in §1.
- **Never push to vault42**: no `make vault42-team-push`, `make vault42-push-all`,
  `42ctl push` or `env push`. Agents do not send secrets off the device. Pulling is the job
  here.
- **Never write to the data center unless the human asks.** That rules out
  `make link-models-migrate`, `make link-demo-login-ensure`, `make link-live-data-ensure`,
  `grobase db migrate`, `grobase host restart|stop`, and `make restore` anywhere.
- **Ask the human, and wait,** for:
  - the VM password, typed once by them for `ssh-copy-id`;
  - the vault42 passphrase and the codes it emails;
  - the Tailscale login;
  - every `sudo`.
- **Do not run `make all` on this device for this test.** It builds and starts a *local*
  grobase, which is the opposite of linking to the data center. `make link-frontends-up`
  (§8) is the command.
- **Record as you go (§9).** UNKNOWN = FAIL: a step you could not run is a `SKIP` with its
  reason, never a `PASS`.

## 1. The data center

| What | Value |
|---|---|
| Host (runs the VM) | LAN `192.168.1.132` (`enp7s0`); Tailscale node `dlesieur42-2`, `100.94.109.44` |
| VM `b2b` | Tailscale node `dlesieur42-1`, `100.94.119.97`, MagicDNS `dlesieur42-1.tail10f2ea.ts.net`; hostname `dlesieur42` |
| grobase | `/opt/grobase` in the VM, branch `main` |
| ssh into the VM | user `dlesieur`, port `4242`, on the Tailscale address or on the host's LAN address |
| API edge (the WAF) | `:8443` on `100.94.119.97`, `dlesieur42-1.tail10f2ea.ts.net` and `192.168.1.132`; Funnel `https://dlesieur42-1.tail10f2ea.ts.net` (port 443, public certificate) |
| CA file (`--ca-file`, `GROBASE_CA_FILE`) | `/opt/grobase/certs/track-binocle-local-ca.pem`, SHA-256 `7B:22:BB:3A:8F:5D:76:84:02:6D:61:26:95:37:35:36:AC:F4:7A:03:29:15:2A:4A:64:DF:1A:C7:92:5B:2F:EE`, valid to 2036-10-07 |
| WAF leaf pin (`--pin-sha256`) | `28e27b66a18a90d701a406fbb479c071a26d08cc2fe250a7bb329d327e780c7a`, valid to 2027-11-12 |
| vault42 | org `univers42`, project `groot`, environment `prod`; CLI image `docker.io/dlesieur/42ctl:latest` |
| Repositories (public) | `https://github.com/Univers42/groot` and `https://github.com/Univers42/grobase-cli`, branch `main` |

The WAF's certificate names `localhost`, `host.docker.internal`, `local-https-proxy`,
`track-binocle.test`, `*.track-binocle.test`, `127.0.0.1`, `dlesieur42-1.tail10f2ea.ts.net`,
`100.94.119.97` and `::1`. It does not name the LAN IP. On the LAN, use the pin (it checks the
certificate, not the name) or a hosts-file name with the CA file.

The values above were read on 2026-10-12. A rebuilt VM is a new Tailscale node: it gets a new
`100.x` address, maybe a new name, and a new leaf certificate. If §5's checks print other
values, stop and ask the human; do not edit the expected values to match.

## 2. Check the device

```sh
for c in git make bash curl openssl ssh docker timeout; do
  command -v "$c" >/dev/null && echo "ok      $c" || echo "MISSING $c"
done
docker info --format 'docker {{.ServerVersion}} {{.SecurityOptions}}'
```

Every line must read `ok` and `docker info` must answer. Rootless Docker is fine: groot then
serves its TLS vhost on `9443` instead of `443`. Go `1.26.9` or later builds the CLI (§7);
without Go, docker builds it. Tailscale is needed only for N4 in §3.

## 3. Choose the network, then join it

| # | Network | Where the device is | API URL for the CLI | `make link` target (§8) | Needs |
|---|---|---|---|---|---|
| N1 | localhost | on the data-center host itself | `https://127.0.0.1:8443` | `ssh://b2b` | nothing: the host's ssh alias already exists |
| N2 | LAN, cable | same router as `192.168.1.132` | `https://192.168.1.132:8443` with the pin | `ssh://dlesieur@192.168.1.132:4242` | its key on the VM (§4) |
| N3 | wifi | same wifi as the host | as N2 | as N2 | a wifi that does not isolate its clients |
| N4 | Tailscale | any network | `https://100.94.119.97:8443` or `https://dlesieur42-1.tail10f2ea.ts.net:8443`, with the pin | `ssh://dlesieur@100.94.119.97:4242`, or `https://100.94.119.97:8443` with the CA file | Tailscale in tailnet `tail10f2ea.ts.net` |
| N5 | ssh tunnel | where ssh reaches the VM but `:8443` does not | `https://127.0.0.1:18443` with the pin | already covered: ssh mode *is* ssh (N2/N4) | an ssh path: N2 or N4 |
| N6 | internet, no Tailscale | anywhere | `https://dlesieur42-1.tail10f2ea.ts.net` (Funnel) | `https://dlesieur42-1.tail10f2ea.ts.net`, no CA file | nothing; **never run with groot yet** (§11) |

**N1, localhost.** Only on the host that runs the VM. Local mode does not apply: grobase runs
inside the VM, not on the host's docker daemon. `ssh://b2b` is the host's alias for
`dlesieur@127.0.0.1:4242`.

**N2 and N3, LAN and wifi.** There is nothing to install. The host's firewall may drop ping,
so test the port:

```sh
timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.1.132/8443' && echo "8443 open" || echo "8443 closed"
timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.1.132/4242' && echo "4242 open" || echo "4242 closed"
```

A guest or campus wifi isolates its clients and both checks time out. That is the network,
not the data center: use N4 or N6.

**N4, Tailscale, with root (your own laptop):**

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up                                # the human opens the URL and logs in with the
                                                 # account that owns the tailnet tail10f2ea.ts.net
tailscale status | grep dlesieur42-1             # the VM is listed
tailscale ping dlesieur42-1                      # "pong from dlesieur42-1 ... via DERP(...)" or "via <ip>:<port>"
getent hosts dlesieur42-1.tail10f2ea.ts.net      # 100.94.119.97: MagicDNS works
```

**N4, Tailscale without root (a 42 seat).** Use userspace mode: no network interface, a SOCKS
proxy instead. Take `tailscale` and `tailscaled` from the static tarball at
`https://pkgs.tailscale.com/stable/#static` and put both on `PATH`:

```sh
mkdir -p "$HOME/.local/share/tailscale"
tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 \
  --state="$HOME/.local/share/tailscale/state" --socket="$HOME/.local/share/tailscale/sock" &
tailscale --socket="$HOME/.local/share/tailscale/sock" up
export HTTPS_PROXY=socks5://127.0.0.1:1055       # the CLI reaches the tailnet through it
```

In this mode ssh needs the proxy too: add `-o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p'`.
Docker containers do not see the proxy, so groot's `make link` cannot use it (§11).

**N5, ssh tunnel.** The tunnel's far end is the VM, whose WAF also listens on its own
`127.0.0.1:8443`:

```sh
ssh -f -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18443:127.0.0.1:8443 -p 4242 dlesieur@100.94.119.97
# on the LAN: ... dlesieur@192.168.1.132
```

**N6, internet.** There is nothing to join. A `401` means Kong answered and wants an API key:
the edge is reachable.

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://dlesieur42-1.tail10f2ea.ts.net/auth/v1/health
```

## 4. ssh access to the VM (N1 to N5)

`make link` (ssh mode) and the CLI's `grobase host` commands run ssh with `BatchMode`: they
never type a password, so this device's key must be on the VM. Copy it once, over the network
the device has:

```sh
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519   # ask the human about a passphrase
ssh-copy-id -p 4242 dlesieur@100.94.119.97        # N4; on N2/N3: dlesieur@192.168.1.132
                                                  # the human types the VM password once
ssh -o BatchMode=yes -p 4242 dlesieur@100.94.119.97 'echo key-ok $(hostname)'   # key-ok dlesieur42
```

The CLI's `--ssh` takes an alias or `user@host`, not a port, so give the VM aliases in
`~/.ssh/config`:

```text
Host dc-tailnet
    HostName 100.94.119.97
    Port 4242
    User dlesieur
Host dc-lan
    HostName 192.168.1.132
    Port 4242
    User dlesieur
```

## 5. The two trust anchors

**The leaf pin** covers every route except Funnel. Check it against the VM before using it:

```sh
ssh -p 4242 dlesieur@100.94.119.97 \
  openssl x509 -noout -fingerprint -sha256 -in /opt/grobase/certs/localhost.pem \
  | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
# must print 28e27b66a18a90d701a406fbb479c071a26d08cc2fe250a7bb329d327e780c7a
```

**The CA file** is what groot's direct link uses, and the CLI when you address the edge by
name. Copy only the certificate; the CA's key never leaves the VM.

```sh
scp -P 4242 dlesieur@100.94.119.97:/opt/grobase/certs/track-binocle-local-ca.pem ~/grobase-ca.pem
openssl x509 -noout -fingerprint -sha256 -in ~/grobase-ca.pem
# must print sha256 Fingerprint=7B:22:BB:3A:8F:5D:76:84:02:6D:61:26:95:37:35:36:AC:F4:7A:03:29:15:2A:4A:64:DF:1A:C7:92:5B:2F:EE
```

**Funnel's certificate is public** (issued through Tailscale), so the system store trusts it.
It needs no pin and no CA file, and the pin above does not match it.

## 6. vault42: the team's secrets on this device

**What the pull brings:** the shared tree of `univers42` / `groot` / `prod`. That is:

- every `*.env*` and `*.secrets` file of groot and its submodules;
- the engine dumps under `secrets/`;
- the team keys that `./.env.local` needs: `OSIONOS_BRIDGE_EMAIL_HASH_SALT` and the
  `VITE_BAAS_*` lines.

Without the salt, every identity seeded into the data center is unfindable from this device's
osionos bridge. Their logins then fail as if the password were wrong (the header of
`scripts/vault42-team.sh` explains why).

**What it does not bring:**

- `*.local` files, which are always private;
- anything someone else pushed with `--private`. The data center's own `.env`
  (`./.env.grobase-remote`) is sealed to the person who pushed it.

This device opens that file only with that person's identity (step 6.2, first option). ssh
mode fetches it over ssh anyway (§8).

**6.1 Clone groot.** The vault scripts live in it. The repository is public, so HTTPS needs no
GitHub key:

```sh
git clone --recursive https://github.com/Univers42/groot.git ~/groot && cd ~/groot
git log --oneline -1                               # record this commit in §9
```

**6.2 An identity on this device.** There are two ways.

- **The data center's owner on a second machine (recommended).** This identity also opens the
  owner's private files. On the data-center host, once, the human runs:

  ```sh
  scripts/vault42-ctl.sh keys escrow --email <owner email>
  ```

  Then here, with the human typing the emailed code and the passphrase:

  ```sh
  scripts/vault42-ctl.sh keys recover --email <owner email>
  scripts/vault42-ctl.sh auth login --password --email <owner email>
  scripts/vault42-ctl.sh auth me                   # names the account; an HTTP 401 means log in again
  ```

- **A teammate with their own identity.** Run `scripts/vault42-ctl.sh keys init`, then
  `scripts/vault42-ctl.sh keys enroll --org univers42`, then an org admin grants the project.
  This identity reads the shared tree, but not the owner's private files.

`scripts/vault42-ctl.sh` runs 42ctl in the same container, with the same keystore
(`~/.config/42ctl`), as the make targets. It asks for the passphrase once, hidden, or reads
`FT_PASSPHRASE` when the human has exported it. A command typed on one line keeps its
arguments together; a terminal wrap once turned `--env prod` into a command.

**6.3 Pull.** A dry run first, then for real:

```sh
make vault42-team-pull                        # dry run: lists the files, writes nothing
make vault42-team-pull APPLY=1 BACKUP=1       # writes them; displaced files go aside as .bak;
                                              # ends "[vault42-team] laid N team key(s) over .env.local"
bash scripts/gen-local-env.sh --check         # "in sync"; drift is reported by key name, never by value
```

On 2026-09-19 the dry run listed 55 files (`docs/RESTART-README.md`); a different count is not
an error by itself. **The order matters: pull before §8.** The pull rebuilds `./.env.local` and
lays the team keys over it. `make link` then runs `gen-local-env.sh --sync`, which rewrites
only the eight keys derived from grobase's `.env` (now the data center's) and leaves every
other line alone (`scripts/gen-local-env.sh:19-24`).

## 7. The grobase CLI

**Install:**

```sh
go install github.com/Univers42/grobase-cli/cmd/grobase@latest     # with Go 1.26.9 or later
# without Go:
mkdir -p ~/.local/bin
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e GOFLAGS=-buildvcs=false \
  -v "$HOME/.local/bin:/out" golang:1.26.9 sh -c \
  'git clone -q --depth 1 https://github.com/Univers42/grobase-cli /tmp/src && cd /tmp/src && CGO_ENABLED=0 go build -o /out/grobase ./cmd/grobase'
grobase version
git clone -q --depth 1 https://github.com/Univers42/grobase-cli ~/grobase-cli   # for scripts/check-routes.sh
```

**Two contexts**, one per trust anchor. Every URL in a context must present the same
certificate, which is why Funnel gets its own. The first URL that answers is used, and one
that does not costs `GROBASE_PROBE_TIMEOUT` (2 s) before the next.

```sh
# the private routes: Tailscale IP, MagicDNS, LAN IP, ssh tunnel (pinned leaf)
grobase context add dc \
  --url https://100.94.119.97:8443 --url https://dlesieur42-1.tail10f2ea.ts.net:8443 \
  --url https://192.168.1.132:8443 --url https://127.0.0.1:18443 \
  --pin-sha256 28e27b66a18a90d701a406fbb479c071a26d08cc2fe250a7bb329d327e780c7a \
  --ssh dc-tailnet
# the internet route: Funnel, public certificate
grobase context add dc-public --url https://dlesieur42-1.tail10f2ea.ts.net
```

On N1, add `--url https://127.0.0.1:8443`. Do not add it anywhere else: on another device,
whatever listens on that port is not the data center.

**An account for this device.** The data center's GoTrue confirms sign-ups at once, so the
device signs up its own test account and no password ever travels. The anon key comes from
`./.env.grobase-remote`: §8's first ssh-mode `make link` writes it, or the owner's vault pull
does.

```sh
EMAIL="device-$(hostname -s)-$(date +%Y%m%d)@example.com"
mkdir -p ~/.config && (umask 077 && openssl rand -base64 24 > ~/.config/grobase-device-password)
{ sed -n 's/^ANON_KEY=//p' ~/groot/.env.grobase-remote; cat ~/.config/grobase-device-password; } \
  | grobase --context dc signup --email "$EMAIL" --anon-key-stdin --password-stdin
grobase --context dc whoami
grobase --context dc doctor        # every row PASS; the reachability row names the URL in use
```

`--anon-key-stdin` reads the first line and `--password-stdin` the next. Later sessions run
`grobase --context dc login --email "$EMAIL" --password-stdin < ~/.config/grobase-device-password`.
The `dc-public` context needs its own `login`, with the same pipe as `signup` (anon key first).

**Every route in one command.** Each route gets a throwaway config, so your contexts are never
touched:

```sh
GROBASE_EMAIL="$EMAIL" GROBASE_PASSWORD="$(cat ~/.config/grobase-device-password)" \
GROBASE_ANON_KEY="$(sed -n 's/^ANON_KEY=//p' ~/groot/.env.grobase-remote)" \
  ~/grobase-cli/scripts/check-routes.sh
```

It prints one line per route: `lan-ip`, `lan-name`, `tailnet-ip`, `magicdns`, `funnel`,
`ssh-lan`, `ssh-tailnet`. Each is `PASS`, `FAIL` with the reason, or `SKIP`. The expected
pattern by location is in CONNECTING.md §6. `lan-name` SKIPs until the device's hosts file
has `192.168.1.132 grobase.track-binocle.test`.

## 8. groot linked to the data center

**8.1 Configure.** `./.env.grobase-link` is git-ignored and documented by the example file:

```sh
cd ~/groot
cp .env.grobase-link.example .env.grobase-link
```

Then set its keys for the network the device is on. Edit the file by its keys, never by
pasting values from an env file.

| Network | `GROBASE_TARGET` | `GROBASE_CA_FILE` | `GROBASE_API_URL` (informational: `scripts/grobase-link.sh api-url`) |
|---|---|---|---|
| N1 | `ssh://b2b` | empty | `https://127.0.0.1:8443` |
| N2, N3 | `ssh://dlesieur@192.168.1.132:4242` | empty | `https://192.168.1.132:8443` |
| N4, ssh | `ssh://dlesieur@100.94.119.97:4242` | empty | `https://100.94.119.97:8443` |
| N4, direct | `https://100.94.119.97:8443` | `$HOME/grobase-ca.pem` (absolute path) | empty (taken from the target) |
| N6 | `https://dlesieur42-1.tail10f2ea.ts.net` | empty (public certificate) | empty |

The modes:

- **ssh mode** relays all five grobase ports (Kong, Redis, Mailpit smtp and http, realtime)
  and copies the data center's `.env` to `./.env.grobase-remote` (mode 600).
- **Direct mode** relays Kong over the URL, with Redis and Mailpit stood in on this device:
  sessions and captured mail stay here. It does not relay realtime, and it cannot fetch
  secrets, so `./.env.grobase-remote` must already exist from an earlier ssh link or the
  owner's vault pull.
- **A URL by hosts-file name** (`grobase.track-binocle.test`) does not work for direct mode:
  the relay runs in a container, which does not read the device's hosts file.

`make link GROBASE_TARGET=... GROBASE_CA_FILE=...` overrides the file for one run.

**8.2 Up and verify:**

```sh
make link-frontends-up     # opens the link, starts the frontends with the relay, puts the edge CA
                           # into this user's browser stores (no sudo), then runs link-verify
make link-verify           # last line: "[grobase-link] verify: N frontends reach grobase through the ... link to ..."
make link-status           # exit 0 while the path is open and Kong answers through it
```

`link-verify` sends one request per grobase name (Kong, Redis, Mailpit smtp and http,
realtime) from inside every frontend, then the browser's path through the TLS edge, then
checks browser trust. It exits 1 on any FAIL. Switch networks with `make link GROBASE_TARGET=...`
and close the link with `make link-down`.

**8.3 Open the apps** (groot's README):

| App | URL |
|---|---|
| opposite-osiris (start here) | `https://localhost:4322` |
| osionos editor | `https://localhost:3001` |
| Whiteboard (drawnosaurus) | `https://localhost:3007` |
| osionos-bridge | `https://localhost:4000` |
| auth-gateway | `https://localhost:8787/api/auth` |

The human signs in in the browser; the agent records what they report.

## 9. The test plan

Run each row on every network the device can reach:

- N1 needs the host;
- N2 and N3 need the same LAN or wifi;
- N4 needs Tailscale;
- N5 needs an ssh path;
- N6 needs only the internet.

A network the device cannot reach is `SKIP (why)`.

| Test | Command | PASS when |
|---|---|---|
| T1 reach | `ROUTES="<route>" ~/grobase-cli/scripts/check-routes.sh` with the credentials of §7 | `PASS  <route> ... login+whoami as <email>` |
| T2 doctor | `grobase --context dc doctor` (N6: `--context dc-public`) | every row PASS; it names the URL of this network |
| T3 identity | `grobase --context dc whoami` | prints this device's email |
| T4 ssh | `ssh -o BatchMode=yes -p 4242 dlesieur@<addr> true` then `grobase --context dc host health` | exit 0, then `N containers of ...: none unhealthy, crash-looping or failed` |
| T5 link | `make link GROBASE_TARGET=<§8 value>`, then `make link-verify` | `verify: N frontends reach grobase through the ... link`, exit 0 |
| T6 browser | the human signs in at `https://localhost:4322` and opens osionos | they see their workspace; no certificate warning |

`<route>` for T1: N2 and N3 `lan-ip ssh-lan`, N4 `tailnet-ip magicdns ssh-tailnet`, N6
`funnel`. N1 and N5 have no check-routes route; use T2 with the `127.0.0.1` URLs of §7.

**What has already been proven** (2026-10-12, from the host and from stand-ins: a container on
the LAN path, a separate Tailscale node relayed through DERP, a container on the public
internet):

- N1: T1, T2, T5;
- N2: T1;
- N4: T1, T2, and T5 direct;
- N6: T1 and T2.

**Never run before this page:** N3 from a physical wifi device, N5 with groot, N6 with groot,
and N4 in userspace mode with groot.

**Results.** Copy this table into a new subsection `### <device>, <yyyy-mm-dd>` at the end of
this page. Head it with: the device's OS, its docker version, the groot commit (§6.1) and
`grobase version`.

| Test | N1 | N2 | N3 | N4 IP | N4 MagicDNS | N5 | N6 |
|---|---|---|---|---|---|---|---|
| T1 reach | | | | | | | |
| T2 doctor | | | | | | | |
| T3 identity | | | | | | | |
| T4 ssh | | | | | | | |
| T5 link | | | | | | | |
| T6 browser | | | | | | | |

Each cell is `PASS`, `FAIL: <one-line reason>` or `SKIP: <why>`. Under the table, paste the
last 20 lines of each failing command. If a secret appears in them, stop and tell the human
instead of pasting.

Then commit only this page, on a branch `docs/device-test-<device>-<yyyymmdd>`. Push the
branch and stop: the human merges it (develop, then main).

## 10. When something fails

| Symptom | Cause | Next step |
|---|---|---|
| `tailscale status` does not list `dlesieur42-1`; every tailnet route FAILs | the VM's node expired (key expiry 2027-04-08) or, its auth key being ephemeral, was removed after it went offline | the human runs `make tailnet` in born2root on the host; then re-read §1's values, which may have changed |
| N2/N3 port checks time out from a wifi device, but work from the host | the wifi isolates its clients | N4 or N6 |
| `doctor` TLS FAIL showing two fingerprints | the leaf was re-issued | re-check §5, then `grobase context pin dc` |
| `make link`: `... does not answer from a container of this daemon` | the relay's container cannot reach that URL: a hosts-file name, or userspace Tailscale | the IP form, or ssh mode |
| `make link`: `cannot read /opt/grobase/.env` | ssh works but the path differs | `GROBASE_REMOTE_DIR=<grobase dir on the VM>` |
| `direct mode cannot fetch secrets` | no `./.env.grobase-remote` | one ssh-mode `make link` first (N2/N4), or the owner's vault pull |
| vault42: `no manifest for project groot` | a personal pull (`VAULT42_ORG` or `VAULT42_ENV` blank), or the project is not granted | leave both at their defaults; ask an org admin for the grant |
| vault42: `HTTP 401`, or `auth status` "logged in" but `auth me` 401 | the server expired the session | `scripts/vault42-ctl.sh auth login --password --email <you>` |
| seeded users fail to log in "with the right password" | `./.env.local` lacks the team keys | §6.3 again, then `make link` |

More symptoms: CONNECTING.md §7 and [grobase-link](grobase-link.md) "Troubleshooting".

## 11. What this page does not prove

- **No physical second device has run it.** The routes were proven from the host and from
  stand-ins (CONNECTING.md §8). §9 on a real device is the first such run, and a wifi that
  isolates clients or a network that blocks Tailscale's relays has not been met.
- **N6 with groot has never run.** Kong admits its admin routes from private source ranges
  only, and Funnel traffic reaches the WAF from the VM's own `tailscaled`. Whether the
  direct link's bridge-publish route answers there is unknown; T5 on N6 will say.
- **Userspace Tailscale with groot is expected to fail.** The relay runs in a container, and
  containers do not see a userspace Tailscale's SOCKS proxy. Expect `make link` to fail there
  while the CLI works.
- **The pin and the addresses are 2026-10-12's.** Re-check §5 every time; never adjust the
  expected values to match what you see.
