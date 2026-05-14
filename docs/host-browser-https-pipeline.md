# Host Browser HTTPS Pipeline

This document is the dense runbook for making Track Binocle work when Docker runs inside the `b2b` VirtualBox VM but the browser runs on the host machine. It explains what was changed, why the fresh `make all` path initially failed, how Firefox and Chrome trust the VM certificate authority, how host `localhost` reaches VM Docker services, and how to debug the certificate and port-forward errors we hit.

The short version is:

```text
host browser -> host localhost:<port> -> VirtualBox NAT -> b2b VM:<port> -> VM Docker published port -> local-https-proxy -> app container
```

That whole chain must be correct. A green Docker stack inside the VM is not enough if the VM publishes ports only on guest `127.0.0.1`, if VirtualBox does not forward the port, if the host browser trusts the wrong CA, or if the browser opens a random forwarded port such as `https://localhost:4323` instead of the canonical Compose port.

## Final State

The working state we validated was:

```text
VM SSH target:       ssh b2b, explicit endpoint 127.0.0.1:4242 as user dlesieur
VM repo:             /home/dlesieur/Documents/track-binocle
VM Docker context:   default
VM Docker engine:    Docker client/server 29.4.3
VM Compose:          Docker Compose v5.1.3
Website URL:         https://localhost:4322
Mailpit URL:         http://localhost:8025
```

The browser-facing VM Docker ports must be published on `0.0.0.0` inside the VM so VirtualBox NAT can reach them:

```text
0.0.0.0:3001 -> osionos app
0.0.0.0:3002 -> Mail
0.0.0.0:3003 -> Calendar
0.0.0.0:4000 -> osionos bridge
0.0.0.0:4100 -> Mail bridge
0.0.0.0:4200 -> Calendar bridge
0.0.0.0:4322 -> website
0.0.0.0:8000 -> BaaS gateway
0.0.0.0:8787 -> auth gateway
0.0.0.0:18200 -> Vault through HTTPS proxy
0.0.0.0:8025 -> Mailpit UI
```

Postgres stays host-loopback inside the VM:

```text
127.0.0.1:5432 -> postgres
```

That is intentional. Browser ports need to cross the VM boundary. The database does not.

## Why The Browser Failed

The failure looked like this:

```text
Certificate Error
This site's security certificate could not be verified. Your connection is not private.
URL: https://localhost:4323/
Error: net::ERR_CERT_AUTHORITY_INVALID
Issuer: Track Binocle Local Development CA
Subject: localhost
```

That means the browser reached a TLS server presenting a `localhost` certificate issued by `Track Binocle Local Development CA`, but the browser did not trust the CA that signed that specific certificate.

There are two important details in that error:

1. The issuer is the expected development CA name, so the browser is not seeing a public-web certificate problem. It is seeing a local CA trust problem.
2. The URL is `https://localhost:4323/`, not the canonical `https://localhost:4322/`. Port `4323` is usually a VS Code or SSH forwarded port, not the Docker Compose website port. A forwarded port can expose a stale VM/service/certificate and should not be treated as the source of truth until it is diagnosed.

The corrected path is to use the canonical URL printed by `make showcase`:

```text
https://localhost:4322
```

If a browser still opens `4323`, close the forwarded port in VS Code or explicitly type `https://localhost:4322/` after the VirtualBox NAT forward exists.

## What Was Changed

### Makefile

The root `Makefile` now defaults Buildx to Docker's local default builder:

```make
BUILDX_BUILDER ?= default
```

This matters in the VM because a stale named `docker-container` builder can make `docker buildx bake` hang or use the wrong build context. The default builder worked in the VM with:

```text
#0 building with "default" instance using docker driver
```

The root `Makefile` also computes and exports the browser-facing bind address:

```make
TRACK_BINOCLE_BIND_ADDR ?= $(shell if [ -r /sys/class/dmi/id/product_name ] && grep -qi 'VirtualBox' /sys/class/dmi/id/product_name 2>/dev/null && ip route 2>/dev/null | grep -q 'default via 10\.0\.2\.2'; then printf '0.0.0.0'; else printf '127.0.0.1'; fi)
export ... TRACK_BINOCLE_BIND_ADDR
```

The thinking behind that line:

- Normal local Docker runs should bind browser ports to `127.0.0.1` for safety.
- A VirtualBox NAT VM must bind browser-facing Docker ports to `0.0.0.0` inside the guest, otherwise the host cannot reach them through NAT.
- VirtualBox NAT guests normally have `10.0.2.2` as their default gateway, so that is a useful automatic signal.

The `Makefile` health checks also verify the plain HTTP to HTTPS redirect:

```text
[healthcheck] website plain HTTP redirects to HTTPS
```

### docker-compose.yml

The `local-https-proxy` and Mailpit UI ports use `TRACK_BINOCLE_BIND_ADDR`:

```yaml
ports:
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${OPPOSITE_OSIRIS_HOST_PORT:-4322}:4322"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${OSIONOS_APP_HOST_PORT:-3001}:3001"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${OSIONOS_BRIDGE_HOST_PORT:-4000}:4000"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${AUTH_GATEWAY_HOST_PORT:-8787}:8787"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${KONG_HTTP_PORT:-8000}:8000"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${KONG_ADMIN_PORT:-8001}:8001"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${MAIL_HOST_PORT:-3002}:3002"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${MAIL_BRIDGE_PORT:-4100}:4100"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${CALENDAR_HOST_PORT:-3003}:3003"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${CALENDAR_BRIDGE_PORT:-4200}:4200"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${VAULT_PORT:-18200}:8200"
```

Mailpit uses the same bind setting for the UI:

```yaml
ports:
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${MAILPIT_HOST_PORT:-8025}:8025"
```

Postgres remains restricted:

```yaml
ports:
  - "127.0.0.1:${PG_PORT:-5432}:5432"
```

### Nginx TLS Proxy

The HTTPS proxy config handles plain HTTP sent to an HTTPS port:

```nginx
error_page 497 =308 https://$host:$server_port$request_uri;
```

Without that, a browser or forwarder that starts with `http://localhost:4322` gets this Nginx response:

```text
400 The plain HTTP request was sent to HTTPS port
```

With the fix, it receives:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://localhost:4322/
```

### Certificate Trust Helper

The local CA trust helper imports the current Track Binocle CA into all places a Linux desktop browser may use:

```text
~/.pki/nssdb
~/.mozilla/firefox/* profiles
~/snap/firefox/common/.mozilla/firefox/* profiles
~/.var/app/org.mozilla.firefox/.mozilla/firefox/* profiles
existing Snap Chromium/Discord NSS DBs
/usr/local/share/ca-certificates/track-binocle-local-ca.crt
```

For Firefox it also writes this preference into each profile's `user.js`:

```js
user_pref("security.enterprise_roots.enabled", true);
```

Firefox must be fully closed and reopened after the import. If Firefox is running, it may keep the old trust state in memory.

## The Debugging Story

This is the actual reasoning path from the working session.

### 1. Host Docker Was A False Positive

The stack first worked when tested on the host Docker daemon. That proved the app code and Compose graph could run, but it did not prove the target environment. The user correctly pointed out that the target was the Docker service inside the `b2b` VM.

The rule after that correction was:

```text
Do not claim success unless the VM Docker daemon runs the stack and the host browser reaches that VM stack.
```

### 2. SSH Was Reachable But Noninteractive Commands Looked Broken

The VM was VirtualBox VM `debian`, with SSH forwarded like this:

```text
Forwarding(...)= "ssh,tcp,,4242,,4242"
```

The explicit SSH endpoint was:

```bash
ssh -p 4242 dlesieur@127.0.0.1
```

Key authentication worked, but noninteractive `ssh 'command'` calls appeared to authenticate and then produce no command output. The reason was the VM login auto-attaches tmux. The reliable access pattern was an interactive TTY:

```bash
ssh -tt -F /dev/null \
  -i ~/.ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p 4242 dlesieur@127.0.0.1
```

Once inside that shell, commands ran normally.

### 3. VirtualBox Guest Control Was Not Available

`VBoxManage guestcontrol` was checked as a fallback, but the VM returned:

```text
The guest execution service is not ready (yet)
```

So the practical route stayed SSH plus the tmux-attached shell.

### 4. The VM Repo Was Not The Same Path As The Host Workspace

The host workspace path was nested under:

```text
/home/dlesieur/Documents/track-binocle/apps/track-binocle/apps/track-binocle
```

The VM repo was:

```text
/home/dlesieur/Documents/track-binocle
```

The VM was checked with:

```bash
cd /home/dlesieur/Documents/track-binocle
git branch --show-current
git rev-parse --short HEAD
git status --short
docker context show
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker compose version
```

### 5. VM `make all` Worked Internally

Inside the VM repo:

```bash
make all
```

This completed the VM-side pipeline:

```text
Vault env fetch complete
AppRole read-check ok
docker buildx bake with default docker driver
docker compose up
make healthcheck
PASS Newsletter confirmation accepted and captured by Mailpit.
PASS BaaS PostgREST gateway responded with HTTP 200.
Pipeline ready.
```

This proved VM Docker was healthy, but host browser access was still not proven.

### 6. Host Browser Access Still Failed Because VM Docker Was Bound To Guest Loopback

From the host, HTTPS initially failed with connection reset / SSL syscall errors. Inside the VM, `docker compose ps local-https-proxy` showed ports like:

```text
127.0.0.1:4322->4322/tcp
```

That is reachable only from inside the VM. VirtualBox NAT forwards to the guest network interface, not to services bound only to guest loopback. The fix was to publish browser-facing ports on `0.0.0.0` inside the VM.

After the bind fix and `make up`, the VM showed:

```text
0.0.0.0:4322->4322/tcp
0.0.0.0:8000->8000/tcp
0.0.0.0:8787->8787/tcp
0.0.0.0:8025->8025/tcp
```

### 7. VirtualBox NAT Forwards Were Required On The Host

The host needed NAT rules so host `localhost:<port>` points at the VM's same port:

```bash
for port in 3001 3002 3003 4000 4100 4200 4322 8000 8787 18200 8025; do
  name="track-binocle-$port"
  if VBoxManage showvminfo debian --machinereadable | grep -q "Forwarding.*=\"$name,"; then
    echo "exists $name"
  else
    VBoxManage controlvm debian natpf1 "$name,tcp,,$port,,$port"
    echo "added $name"
  fi
done
```

After that, `ss` on the host showed listeners for the forwarded ports:

```bash
ss -ltnp '( sport = :4322 or sport = :8025 )'
```

### 8. The Host Browser Still Needed The VM CA, Not The Host CA

The VM generated its own CA under:

```text
apps/baas/certs/track-binocle-local-ca.pem
```

The host already had a Track Binocle CA from an earlier host-Docker run, but that was not necessarily the same CA as the VM's current CA. Same common name does not mean same key. Trust is based on the CA certificate fingerprint.

The VM CA fingerprint was checked with:

```bash
openssl x509 \
  -in apps/baas/certs/track-binocle-local-ca.pem \
  -noout -fingerprint -sha256 -subject -dates
```

The live certificate served through the host-forwarded port was checked with:

```bash
timeout 5 openssl s_client \
  -connect localhost:4322 \
  -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

To trust the VM CA on the host, the public CA was copied to the host and imported with the existing helper. A manual no-`scp` method is:

```bash
# Inside the VM
cd /home/dlesieur/Documents/track-binocle
base64 -w0 apps/baas/certs/track-binocle-local-ca.pem
```

On the host:

```bash
tmpdir=/tmp/track-binocle-b2b-ca
mkdir -p "$tmpdir"

# Paste the VM CA base64 between the markers.
base64 -d > "$tmpdir/track-binocle-local-ca.pem" <<'B64'
PASTE_VM_CA_BASE64_HERE
B64

TRACK_BINOCLE_CERT_DIR="$tmpdir" \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

That imports the VM CA into browser NSS stores and the Linux system CA store. It may prompt for host sudo.

The helper printed successful imports like:

```text
Trusted local CA in NSS database: /home/dlesieur/.pki/nssdb
Trusted local CA in NSS database: /home/dlesieur/snap/firefox/common/.mozilla/firefox/<profile>
Enabled Firefox enterprise roots in profile: /home/dlesieur/snap/firefox/common/.mozilla/firefox/<profile>
Trusted local CA in the Linux system CA store.
```

After this, fully quit Firefox and reopen it.

## Fresh Developer Procedure

Use this when a teammate starts fresh and Docker is supposed to run inside the `b2b` VM while the browser runs on the host.

### 1. Start And Confirm The VM

On the host:

```bash
VBoxManage list runningvms
VBoxManage showvminfo debian --machinereadable | grep -E '^(name=|VMState=|Forwarding)'
```

Confirm SSH is forwarded:

```text
Forwarding(...)= "ssh,tcp,,4242,,4242"
```

Connect:

```bash
ssh b2b
```

If the alias is missing, use the explicit form:

```bash
ssh -tt -F /dev/null \
  -i ~/.ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p 4242 dlesieur@127.0.0.1
```

### 2. Confirm Docker Is The VM Docker

Inside the VM:

```bash
cd /home/dlesieur/Documents/track-binocle
docker context show
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker compose version
git status --short
```

You should see Docker client and server versions from inside the VM. Do not run the validation from the host repo and call it done.

### 3. Add Host-To-VM NAT Forwards

On the host:

```bash
for port in 3001 3002 3003 4000 4100 4200 4322 8000 8787 18200 8025; do
  name="track-binocle-$port"
  if VBoxManage showvminfo debian --machinereadable | grep -q "Forwarding.*=\"$name,"; then
    echo "exists $name"
  else
    VBoxManage controlvm debian natpf1 "$name,tcp,,$port,,$port"
    echo "added $name"
  fi
done
```

Check host port conflicts before blaming certificates:

```bash
ss -ltnp '( sport = :4322 or sport = :3001 or sport = :3002 or sport = :3003 or sport = :4000 or sport = :4100 or sport = :4200 or sport = :8000 or sport = :8787 or sport = :18200 or sport = :8025 )'
```

If host Docker is already using those ports, stop the host stack first. Otherwise the browser may hit host Docker instead of the VM.

### 4. Run The VM Pipeline

Inside the VM:

```bash
cd /home/dlesieur/Documents/track-binocle
make all
```

If the stack already exists and only the bind or Nginx config changed:

```bash
make up
```

Then verify inside the VM:

```bash
make healthcheck
docker compose ps local-https-proxy mailpit
```

Expected VM proxy binding in a VirtualBox NAT VM:

```text
0.0.0.0:4322->4322/tcp
0.0.0.0:8000->8000/tcp
0.0.0.0:8787->8787/tcp
0.0.0.0:8025->8025/tcp
```

If it still shows `127.0.0.1:4322->4322/tcp`, recreate with the VM bind variable:

```bash
TRACK_BINOCLE_BIND_ADDR=0.0.0.0 make up
```

### 5. Trust The VM CA On The Host

If the browser runs on the host, trust the VM CA on the host. Do not trust a host-generated CA and assume it matches the VM CA.

Fast path when `scp` works:

```bash
mkdir -p /tmp/track-binocle-b2b-ca
scp -P 4242 dlesieur@127.0.0.1:/home/dlesieur/Documents/track-binocle/apps/baas/certs/track-binocle-local-ca.pem \
  /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

Fallback path when `scp` is blocked by VM login/tmux configuration:

```bash
# VM shell
cd /home/dlesieur/Documents/track-binocle
base64 -w0 apps/baas/certs/track-binocle-local-ca.pem
```

```bash
# Host shell
mkdir -p /tmp/track-binocle-b2b-ca
base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem <<'B64'
PASTE_VM_CA_BASE64_HERE
B64

TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

The noninteractive version used during debugging was:

```bash
timeout 15 ssh -tt -F /dev/null \
  -i ~/.ssh/id_ed25519 \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p 4242 dlesieur@127.0.0.1 \
  'cd /home/dlesieur/Documents/track-binocle && base64 -w0 apps/baas/certs/track-binocle-local-ca.pem' \
  </dev/null > /tmp/track-binocle-b2b-ca.b64

mkdir -p /tmp/track-binocle-b2b-ca
base64 -d /tmp/track-binocle-b2b-ca.b64 > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

Close every Firefox process after this:

```bash
pkill -x firefox || true
pkill -x firefox.real || true
```

If the shell can see Firefox but cannot signal it because the host desktop and the shell are in different snap/systemd namespaces, stop the user scopes instead:

```bash
systemctl --user list-units --type=scope --type=service --all | grep -i firefox
systemctl --user stop app-firefox_firefox-*.scope snap.firefox.firefox-*.scope
```

Then reopen Firefox and go to:

```text
https://localhost:4322/
```

### 6. Verify From The Host

On the host:

```bash
curl -sS -o /dev/null -w 'system_https_4322=%{http_code}\n' https://localhost:4322/
curl -sS -o /dev/null -w 'http_4322=%{http_code} redirect=%{redirect_url}\n' http://localhost:4322/
curl -sS -o /dev/null -w 'system_https_auth=%{http_code}\n' https://localhost:8787/api/auth/availability
curl -sS -o /dev/null -w 'mailpit_8025=%{http_code}\n' http://localhost:8025/
```

Expected:

```text
system_https_4322=200
http_4322=308 redirect=https://localhost:4322/
system_https_auth=200
mailpit_8025=200
```

Inspect the live certificate:

```bash
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

The issuer must be:

```text
issuer=CN = Track Binocle Local Development CA
```

If curl succeeds but Firefox fails, Firefox has stale process state or a different profile. Fully quit Firefox and verify the profile import.

## Firefox Trust Details

Firefox on Linux can ignore the system CA store unless configured. This project handles both paths:

1. It imports the CA directly into Firefox NSS databases with `certutil`.
2. It enables `security.enterprise_roots.enabled=true`, so Firefox can also read the Linux system trust store.

Useful checks on the host:

```bash
certutil -L -d sql:$HOME/.pki/nssdb -n 'Track Binocle Local Development CA' || true
```

For Snap Firefox:

```bash
find "$HOME/snap/firefox/common/.mozilla/firefox" -name cert9.db -print
find "$HOME/snap/firefox/common/.mozilla/firefox" -name user.js -print -exec grep -H 'security.enterprise_roots.enabled' {} \;
```

For regular Firefox:

```bash
find "$HOME/.mozilla/firefox" -name cert9.db -print
find "$HOME/.mozilla/firefox" -name user.js -print -exec grep -H 'security.enterprise_roots.enabled' {} \;
```

If a new CA was generated, rerun the host import. The common name may be the same while the fingerprint changes.

## Chrome And Chromium Trust Details

Chrome/Electron usually trust the Linux system CA store, and Chromium/Snap Chromium can also use NSS databases. The helper imports both:

```text
Linux system CA store
~/.pki/nssdb
existing Snap Chromium NSS stores
```

After import, restart Chrome/Chromium if a tab still shows `ERR_CERT_AUTHORITY_INVALID`.

## Port 4322 Versus 4323

Use `4322` as the source of truth for the website. A URL like this is suspicious:

```text
https://localhost:4323/
```

It may be a VS Code forwarded port, a stale SSH tunnel, or a browser tab from an earlier run. Diagnose it before trusting it:

```bash
for port in 4322 4323; do
  echo "port=$port"
  timeout 5 openssl s_client -connect localhost:$port -servername localhost </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates 2>/dev/null || true
done
```

Also compare HTTP behavior:

```bash
for port in 4322 4323; do
  curl -sS -o /dev/null -w "http_$port=%{http_code} redirect=%{redirect_url}\n" "http://localhost:$port/" || true
done
```

The canonical Docker proxy should redirect plain HTTP to HTTPS. If `4323` serves a different certificate, has a different fingerprint, or fails while `4322` works, close the forwarded port and use `4322`.

## Error Map

### `net::ERR_CERT_AUTHORITY_INVALID`

Meaning:

```text
The host browser does not trust the CA that signed the certificate it received.
```

Fix:

```bash
# Copy the VM CA to the host, then:
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

Then fully restart Firefox/Chrome.

### `SSL_ERROR_SYSCALL` Or `Connection reset by peer` From Host Curl

Meaning:

```text
The host reached the VirtualBox NAT listener, but the VM service was not reachable behind it.
```

Most common cause:

```text
VM Docker port is bound to guest 127.0.0.1 instead of 0.0.0.0.
```

Fix inside the VM:

```bash
TRACK_BINOCLE_BIND_ADDR=0.0.0.0 make up
docker compose ps local-https-proxy
```

### `400 The plain HTTP request was sent to HTTPS port`

Meaning:

```text
Nginx received HTTP on a TLS-only listener and does not have the 497 redirect config active.
```

Fix:

```bash
make up
curl -i http://localhost:4322/ | sed -n '1,8p'
```

Expected:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://localhost:4322/
```

### Host `localhost:4322` Hits The Wrong Stack

Meaning:

```text
Host Docker or another process owns the port, so the browser is not reaching the VM.
```

Check on the host:

```bash
ss -ltnp 'sport = :4322'
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E 'track-binocle|mini-baas|local-https|opposite|mail|calendar|auth|vault' || true
```

Stop the host stack if the VM is the target.

### SSH Auth Works But `ssh b2b command` Prints Nothing

Meaning:

```text
The VM account auto-attaches tmux at login and interferes with noninteractive command output.
```

Use an interactive shell:

```bash
ssh -tt -p 4242 dlesieur@127.0.0.1
```

Then run the commands inside the shell.

## Command Log From The Solved Iteration

These are the important commands used, with secrets omitted.

Host VM discovery:

```bash
ss -ltnp 'sport = :4242' || true
VBoxManage list runningvms
VBoxManage showvminfo debian --machinereadable | grep -E '^(name=|VMState=|Forwarding)'
```

SSH into b2b:

```bash
ssh -tt -F /dev/null \
  -i ~/.ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p 4242 dlesieur@127.0.0.1
```

VM repo and Docker checks:

```bash
cd /home/dlesieur/Documents/track-binocle
git branch --show-current
git rev-parse --short HEAD
git status --short
docker context show
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker compose version
```

VM pipeline:

```bash
make all
make up
make healthcheck
docker compose ps local-https-proxy mailpit
```

Host NAT forwards:

```bash
for port in 3001 3002 3003 4000 4100 4200 4322 8000 8787 18200 8025; do
  name="track-binocle-$port"
  if VBoxManage showvminfo debian --machinereadable | grep -q "Forwarding.*=\"$name,"; then
    echo "exists $name"
  else
    VBoxManage controlvm debian natpf1 "$name,tcp,,$port,,$port"
    echo "added $name"
  fi
done
```

Host certificate and endpoint checks:

```bash
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates

curl -sS -o /dev/null -w 'system_https_4322=%{http_code}\n' https://localhost:4322/
curl -sS -o /dev/null -w 'http_4322=%{http_code} redirect=%{redirect_url}\n' http://localhost:4322/
curl -sS -o /dev/null -w 'system_https_auth=%{http_code}\n' https://localhost:8787/api/auth/availability
curl -sS -o /dev/null -w 'mailpit_8025=%{http_code}\n' http://localhost:8025/
```

VM CA import on host:

```bash
timeout 15 ssh -tt -F /dev/null \
  -i ~/.ssh/id_ed25519 \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p 4242 dlesieur@127.0.0.1 \
  'cd /home/dlesieur/Documents/track-binocle && base64 -w0 apps/baas/certs/track-binocle-local-ca.pem' \
  </dev/null > /tmp/track-binocle-b2b-ca.b64

mkdir -p /tmp/track-binocle-b2b-ca
base64 -d /tmp/track-binocle-b2b-ca.b64 > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  apps/baas/scripts/trust-localhost-cert.sh --system
```

Browser validation:

```text
Open https://localhost:4322/
Expected page title: Prismatica - Everything. One Space.
```

## Final Verification Checklist

The setup is good only when all of these are true:

```text
[ ] Commands were run against VM Docker, not host Docker.
[ ] docker compose ps local-https-proxy in the VM shows 0.0.0.0:4322->4322/tcp.
[ ] VirtualBox has NAT forwards for the required ports.
[ ] Host curl https://localhost:4322/ returns 200 without --cacert.
[ ] Host curl http://localhost:4322/ returns 308 to https://localhost:4322/.
[ ] Host curl https://localhost:8787/api/auth/availability returns 200.
[ ] Host curl http://localhost:8025/ returns 200.
[ ] Firefox was fully restarted after importing the VM CA.
[ ] The browser uses https://localhost:4322/, not an unexplained forwarded 4323 URL.
```

## Conclusion

The root cause was not one single Docker or certificate bug. It was a chain problem:

```text
VM Docker was healthy, but the browser lived on the host.
Host localhost needed VirtualBox NAT forwards.
VirtualBox NAT needed VM Docker ports bound to the VM interface, not guest loopback.
The host browser needed to trust the VM-generated CA, not an older host-generated CA.
Firefox needed NSS/profile import plus enterprise roots plus a full restart.
```

Once every link in that chain was fixed, the host browser reached the VM Docker stack over `https://localhost:4322/` and rendered Prismatica with a trusted certificate.