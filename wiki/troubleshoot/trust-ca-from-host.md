# Trust the Track Binocle Local CA (`https://localhost:4322`)

---

## Overview

When the app runs behind a local HTTPS proxy (port `4322`), TLS is terminated by a **self-signed Certificate Authority (CA)** generated in the repo — not a public CA like Let's Encrypt. Browsers reject certificates they cannot trace back to a trusted root, so you must explicitly import that CA into each browser's trust store.

The situation becomes more complex when the browser runs on a **different machine than the server**:

- If the server runs in a VM and you forward port `4322` over SSH, the cert the browser sees is signed by the **VM's CA**, not the one in your local checkout.
- If a Docker container handles TLS, the CA file may come from a **bind-mounted host directory** rather than the repo tree.

These two sources can have different CA fingerprints. Importing the wrong CA does nothing. The diagnosis steps below tell you exactly which CA is signing the live cert so you import the right one.

**Browsers use different trust mechanisms:**
- **Firefox** reads a per-profile NSS database (`cert9.db`). You must import the CA with `certutil` or via the `trust-localhost-cert.sh` helper.
- **Chrome / Chromium** on Linux reads either the OS CA store (`update-ca-certificates`) or per-profile NSS DBs under `~/.config` and `~/.var/app` (Flatpak). Both may need updating.
- **NSS DB formats**: modern NSS uses the SQL format (`cert9.db` + `key4.db`, addressed with `sql:` prefix). Legacy DBM format uses `cert8.db`. Always use `certutil -d "sql:/path"`.

> **42 school / Flatpak note:** On machines where both Firefox and Chrome are installed as Flatpak bundles (common at 42 school), browsers store their NSS databases at non-standard paths that the repo helper may not detect. See [Flatpak path detection issue](#flatpak-profile-path-detection-issue) for the manual import that reliably covers all cases.

---

## Prerequisites

- SSH access to the VM aliased as `b2b` in your SSH config.
- Working directory: repo root (`/sgoinfre/students/dlesieur/ft_transcendence`), or adjust paths accordingly.
- `certutil` is needed for NSS/Firefox imports. If it is missing and you cannot `sudo`, see [Get certutil without sudo](#4-get-certutil-without-sudo-no-install).
- Only the **public CA PEM** is ever copied between machines. Never copy private keys.

> **What survives a reboot and what doesn't:**
> - **Survives**: the CA import itself. NSS databases live in `$HOME` (`~/.pki`, `~/.config`, `~/.var/app`) and persist across reboots. Once imported, the browser trusts the CA permanently until the cert is regenerated.
> - **Does NOT survive**: `/tmp/track-binocle-b2b-ca/` (the copied CA file) and `/tmp/track-binocle-cert-tools/` (the extracted `certutil` binary) are both wiped on reboot. If you need to re-import (e.g. after `make certs` regenerates certs on the VM), you must redo steps 1–4 of the cheat sheet.

---

## Quick Start

If you just need to (re-)run the full trust flow and your browser runs on the same machine as the server:

```bash
# 1. Generate local certs
make certs

# 2. Import into user-level browser stores (Firefox/Chromium NSS)
make certs-trust-local

# 3. If your browser runs on another host (SSH-forwarded port, remote desktop):
make certs-trust-browser-host

# 4. Check everything is wired up
make certs-doctor
```

If any step fails, work through the detailed guide below to understand exactly what is happening.

---

## How to Diagnose Which CA the Browser Is Seeing

Before importing any CA, confirm that the fingerprint of the CA you are about to import matches the issuer fingerprint of the cert the server is actually serving. A mismatch is the most common reason the browser still rejects the cert after an import.

**Do this in order — each step narrows down the problem:**

**Step A — Check where you are running:**
```bash
# Confirm you are on the host machine (not inside the VM).
# All SSH commands below assume you are on the host.
hostname && whoami && pwd
```

On 42 school machines you should see the cluster hostname (e.g. `c2r19s4.42madrid.com`), not the VM hostname. If you see the VM hostname, you are already inside the VM — skip the `ssh b2b` prefix on all commands.

**Step B — Inspect the live cert being served:**
```bash
# What certificate does localhost:4322 actually serve right now?
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

Note the `Issuer` CN. If it says `CN=Track Binocle Local Development CA`, you have the right CA name — you now need to find which machine holds that CA file.

**Step C — Get the VM CA fingerprint (via SSH, before copying anything):**
```bash
# SSH into the VM and print the CA fingerprint directly — no file transfer yet.
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "openssl x509 -in /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem \
   -noout -fingerprint -sha256 -subject -dates"
```

**Step D — Compare.** The `Issuer CN` from Step B must match the `subject CN` from Step C (both should read `CN=Track Binocle Local Development CA`). Do **not** compare the `sha256 Fingerprint` values directly — Step B prints the fingerprint of the *server cert*, Step C prints the fingerprint of the *CA cert*; these are different certificates and will never share the same fingerprint. The actual chain relationship is verified by the `openssl verify -CAfile` command in Step E. If the issuer CN does not match, the port is served by a different CA source (Docker container or different VM checkout); do not proceed until it matches.

**Step E — Copy and verify the chain (after copying the CA file):**
```bash
# Only run this after completing the "Copy the VM CA to your host" step below
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem "$tmp_cert" \
  && echo "Chain: OK" || echo "Chain: MISMATCH — wrong CA"
rm -f "$tmp_cert"
```

If the issuer fingerprint of the live cert does **not** match the VM CA, the browser is being served by a different source — most likely a Docker container with its own bind-mounted certs (see [Docker container inspection](#docker-container-inspection)), or the VM has multiple checkouts with different CAs.

---

## Step-by-step Guide

### 0. Confirm you are on the right host

Every command below that uses `ssh b2b` assumes you are on the **host machine** (your workstation or 42 school cluster node), not inside the VM.

```bash
# Print hostname, username, and current directory.
# Expected on 42 school: something like c2r19s4.42madrid.com / dlesieur
hostname && whoami && pwd

# Confirm the SSH tunnel to b2b is active (process should appear in the list)
ps -eo pid,user,comm,args | grep 'ssh b2b' | grep -v grep || echo "WARNING: ssh b2b not running — port 4322 forward may be down"
```

If `ssh b2b` is not running, restart it:
```bash
ssh b2b -N -f   # -N: no remote command, -f: go to background
# or simply open a terminal tab and run:
ssh b2b
# and leave it open; VS Code's remote tunnel does this automatically
```

---

### 1. Generate certs

```bash
# From repo root — generates the local CA and server cert
bash apps/baas/scripts/generate-localhost-cert.sh
# or via Makefile
make certs
```

### 2. Identify what owns port 4322

Before deciding which CA to import, confirm whether port `4322` is served locally, forwarded from a VM, or owned by a Docker container.

```bash
# Show the listening socket and owning process
ss -ltnp 'sport = :4322' || true
fuser -v 4322/tcp 2>&1 || true
ps -eo pid,user,comm,args | grep -E '4322|local-https-proxy|nginx|astro|node|ssh|socat' | grep -v grep || true

# List Docker containers and compose services
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed -n '1,80p'
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.State}}\t{{.Ports}}' 2>/dev/null || true

# Fallback: lsof / netstat if available
command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:4322 -sTCP:LISTEN || true
command -v netstat >/dev/null 2>&1 && netstat -ltnp 2>/dev/null | grep ':4322' || true
```

**Interpreting the output:**

- If you see an active `ssh` process or `ssh b2b` listed, port `4322` is an SSH-forward to the VM → follow **Case B**.
- If you see a Docker container (commonly `track-binocle-local-https-proxy-1`) → follow **Docker container inspection** then **Case B** to get the right CA.
- If you see a local `node`, `nginx`, or similar process → follow **Case A**.

---

### Case A — Server runs locally: trust the repo CA directly

```bash
# User-level import (certutil required for NSS / Firefox)
bash apps/baas/scripts/trust-localhost-cert.sh

# System CA store (requires sudo — needed for Chrome / Electron on most distros)
sudo bash apps/baas/scripts/trust-localhost-cert.sh --system

# Makefile equivalents
make certs-trust-local
make certs-trust-system   # sudo
```

If `certutil` is missing the script will still advise on the system install path and tell you to install `libnss3-tools`. See [Get certutil without sudo](#5-get-certutil-without-sudo-no-install) if you cannot use `apt install`.

---

### Case B — Port forwarded from VM: copy the VM CA

When port `4322` is forwarded from the VM, the cert is signed by the **VM's CA**, not the one in your local checkout. You need to copy that public CA to your host and import it.

#### Find the VM CA path

```bash
# Run from your host — SSH into b2b and locate the CA file
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  'printf "host=%s user=%s home=%s\n" "$(hostname)" "$(id -un)" "$HOME"; \
   find "$HOME" /sgoinfre/students/dlesieur -maxdepth 6 \
     -path "*/apps/baas/certs/track-binocle-local-ca.pem" -print 2>/dev/null | head -20'
```

Common VM CA path: `/home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem`

#### Docker container inspection

If `docker ps` shows a container on port `4322`, the TLS files may come from a **bind-mounted host directory** inside the container. Inspect the mounts to find that directory:

```bash
# Show which container exposes 4322
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' | grep 4322"

# Inspect mounts of that container (replace <container> with the name found above)
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "docker inspect --format '{{range .Mounts}}{{println .Source \"->\" .Destination}}{{end}}' <container>"

# If the mount source is e.g. /home/dlesieur/ft_transcendence/apps/baas/certs,
# copy the CA from that path (no private keys transferred)
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" \
  | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
```

#### Copy the VM CA to your host (public cert only)

```bash
# Create a local temp directory
mkdir -p /tmp/track-binocle-b2b-ca

# Transfer only the public CA PEM via SSH + base64 (no private keys)
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" \
  | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

# Verify the copied file is a valid certificate and inspect its fingerprint
openssl x509 -in /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  -noout -fingerprint -sha256 -subject -dates
```

Compare this fingerprint to the issuer fingerprint of the live cert (from the [diagnosis step](#how-to-diagnose-which-ca-the-browser-is-seeing)). They must match before proceeding.

---

### 3. Remote browser host (browser on a third machine)

If the browser runs on a machine that is neither the server nor the VM (e.g. your laptop connecting via an SSH tunnel), use the auto-detect helper:

```bash
# Auto-detects the SSH client/gateway and copies + imports the CA remotely
make certs-trust-browser-host
# or directly
bash apps/baas/scripts/trust-browser-host-ca.sh

# If auto-detect fails, specify the host and port explicitly:
TRACK_BINOCLE_BROWSER_HOST=user@host \
TRACK_BINOCLE_BROWSER_HOST_PORT=2222 \
  make certs-trust-browser-host
```

If SSH to the browser host is not possible, copy the CA file manually and then follow the import steps below.

---

### 4. Get certutil without sudo (no-install)

`certutil` is part of the `libnss3-tools` package. If you cannot `sudo apt install` it, extract the binary from the `.deb` into a temp directory:

```bash
# Create a temp workspace
mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools

# Optional: inspect candidate package version
apt-cache policy libnss3-tools || true

# Download the .deb without installing it (no sudo required)
apt-get download libnss3-tools || true

# Find the downloaded .deb
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)

# Extract certutil into a local root (dpkg-deb, no sudo)
if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$deb" root
  export PATH="$(pwd)/root/usr/bin:$PATH"
else
  echo "warning: libnss3-tools .deb not found or dpkg-deb missing; certutil may be unavailable"
fi

# Confirm certutil is available
command -v certutil || true
```

**Notes:**
- `apt-get download` only downloads the `.deb`; it does not install anything and requires no `sudo`.
- On 42 school machines, the command may print `W: Unable to read /etc/apt/preferences.d/mozilla - open (13: Permission denied)`. This is a harmless warning about a Mozilla-managed apt preference file you do not have access to. The download still succeeds.
- If your environment restricts outbound apt access or the mirror is unavailable, download the `.deb` on another machine and transfer it.
- Confirm the extracted binary matches your host architecture: `file $(pwd)/root/usr/bin/certutil`.

---

### 5. Import the CA into Firefox / NSS

Once you have the CA file (either the repo CA from Case A, or the VM CA copied in Case B) and `certutil` is available:

```bash
# Import using the repo helper — searches for all Firefox profile NSS DBs automatically
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH \
  sh apps/baas/scripts/trust-localhost-cert.sh

# If certutil is already globally available, the PATH override is not needed:
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
  sh apps/baas/scripts/trust-localhost-cert.sh
```

The helper will:
- Import into all found Firefox profile NSS DBs (`cert9.db`).
- Set the enterprise roots preference when relevant.
- Print the exact `sudo` command for a system-level install if you want global trust.

**Expected output (example):**
```
[certs] Using certutil: /tmp/track-binocle-cert-tools/root/usr/bin/certutil
Trusted local CA in NSS database: /home/you/.pki/nssdb
Trusted local CA in existing NSS database: /home/you/.var/app/com.google.Chrome/data/pki/nssdb
Done. Fully quit and restart Chrome/Chromium/Firefox, then reopen the dev URL.
```

**Verify the import worked before restarting Firefox:**
```bash
export TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
printf '[certs] Using certutil: %s\n' "$(command -v certutil)"
TRACK_BINOCLE_CERT_DIR="$TRACK_BINOCLE_CERT_DIR" PATH="$PATH" \
  sh apps/baas/scripts/trust-localhost-cert.sh
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile "$TRACK_BINOCLE_CERT_DIR/track-binocle-local-ca.pem" "$tmp_cert"
rm -f "$tmp_cert"
```

---

### 6. Import the CA into Chrome / Chromium

Chrome on Linux trusts certificates through two mechanisms: the OS CA store and per-profile NSS databases. You may need both, depending on how Chrome is installed.

#### Flatpak profile path detection issue

The `trust-localhost-cert.sh` helper searches for the Firefox Flatpak profile at `~/.var/app/org.mozilla.firefox/.mozilla/firefox/`. On some systems (confirmed on 42 school machines with `org.mozilla.firefox` Flatpak), the actual profile path is:

```
~/.var/app/org.mozilla.firefox/config/mozilla/firefox/<profile>/cert9.db
```

This means the helper's Firefox-specific code will **miss that profile**. The broad `find` pass may catch it as a Chromium-style NSS DB, or it may not be imported at all.

**The safe approach: use `find` to discover all `cert9.db` files and import into every one of them.** This covers Firefox, Chrome, and any other NSS-based browser regardless of install method:

```bash
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
CA=/tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
NICK="Track Binocle Local Development CA"

find "$HOME/.mozilla" "$HOME/.config" "$HOME/.var/app" "$HOME/.pki" \
  -type f -name cert9.db -print 2>/dev/null \
  | while IFS= read -r cert_db; do
      dir="$(dirname "$cert_db")"
      echo "Importing into: $dir"
      certutil -A -d "sql:$dir" -n "$NICK" -t "C,," -i "$CA" && echo "  OK" || echo "  FAILED (may already exist)"
    done
```

On the 42 school setup this reliably imports into all four databases simultaneously:
- `~/.pki/nssdb` — shared NSS store (used by older Chromium builds)
- `~/.var/app/com.google.Chrome/data/pki/nssdb` — Chrome Flatpak
- `~/.config/mozilla/firefox/<profile>` — Firefox system install profile
- `~/.var/app/org.mozilla.firefox/config/mozilla/firefox/<profile>` — Firefox Flatpak profile

You can confirm what was found and imported with:

```bash
find "$HOME/.mozilla" "$HOME/.config" "$HOME/.var/app" "$HOME/.pki" \
  -type f -name cert9.db -print 2>/dev/null
```

**Verify each import actually took effect** using `certutil -L`. It should print `Trust Flags: Trusted CA` for the certificate:

```bash
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
NICK="Track Binocle Local Development CA"

find "$HOME/.mozilla" "$HOME/.config" "$HOME/.var/app" "$HOME/.pki" \
  -type f -name cert9.db -print 2>/dev/null \
  | while IFS= read -r cert_db; do
      dir="$(dirname "$cert_db")"
      result=$(certutil -L -d "sql:$dir" -n "$NICK" 2>/dev/null | grep -c "Trusted CA" || true)
      printf "%-70s %s\n" "$dir" "$([ "${result:-0}" -gt 0 ] && echo 'TRUSTED' || echo 'NOT FOUND — import may have failed')"
    done
```

Expected output — every line should say `TRUSTED`:
```
/home/dlesieur/.pki/nssdb                                              TRUSTED
/home/dlesieur/.var/app/com.google.Chrome/data/pki/nssdb               TRUSTED
/home/dlesieur/.config/mozilla/firefox/i0gio2yh.default-release        TRUSTED
/home/dlesieur/.var/app/org.mozilla.firefox/config/mozilla/firefox/...  TRUSTED
```

#### Per-profile NSS import via helper (no sudo)

```bash
# Run the Chrome-specific helper
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca \
PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH \
  sh apps/baas/scripts/trust-chrome-cert.sh
```

The helper imports the CA into all `cert9.db` NSS databases found under:
- `~/.config/google-chrome`
- `~/.config/chromium`
- `~/.config/BraveSoftware`
- `~/.var/app/com.google.Chrome/data/pki/nssdb` (Flatpak)
- `~/.pki/nssdb` (shared NSS store)

If the helper reports no imports, fall back to the `find`-based loop above.

#### Ephemeral profile test (confirm Chrome accepts the CA before touching your real profile)

```bash
certutil -N -d "sql:/tmp/chrome-profile-trust" --empty-password
certutil -A -d "sql:/tmp/chrome-profile-trust" \
  -n "Track Binocle Local Development CA" -t "C,," \
  -i /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
google-chrome --user-data-dir=/tmp/chrome-profile-trust --no-first-run \
  --headless --disable-gpu --dump-dom https://localhost:4322 || true
```

If headless Chrome returns the DOM and exits `0`, Chrome accepted the TLS chain for that profile.

#### System-wide install (requires sudo — recommended for Chrome / Electron)

Many Chromium builds on Linux read the OS CA store. This is required for Electron apps and is the most reliable path for Chrome:

```bash
sudo cp /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  /usr/local/share/ca-certificates/track-binocle-local-ca.crt
sudo update-ca-certificates
```

---

### 7. Restart the browser

NSS trust changes are read at browser startup. A running browser process will not see newly imported CAs until it is fully quit and reopened.

```bash
# Firefox — graceful then forceful quit
pkill -x firefox-bin || true
pkill -x firefox || true
pkill -TERM -f '/usr/lib/firefox/firefox-bin' || true
pkill -TERM -f '/usr/lib/firefox/crashhelper' || true
# Confirm no Firefox process remains
pgrep -af 'firefox|firefox-bin' | sed -n '1,6p' || true
# Relaunch
firefox https://localhost:4322/ >/tmp/track-binocle-firefox.log 2>&1 & disown

# Chrome / Chromium — graceful then forceful quit
# Use Flatpak app ID first. Do NOT use `pkill -f 'chrome'` (bare pattern):
# it matches any process whose args contain "chrome" (e.g. Claude Code --no-chrome)
# and kills unrelated parent processes / terminates your shell session.
flatpak kill com.google.Chrome 2>/dev/null || pkill -f '/app/extra/chrome' 2>/dev/null || true
sleep 1
pgrep -af 'chrome|chromium|firefox|firefox-bin' | grep -v grep || true
# Relaunch
google-chrome https://localhost:4322/ & disown || true
```

> **Why this is required:** browsers cache trust state in-process. Imports made to the NSS database while the browser is running do not take effect until the process is fully restarted.

---

### 8. Final verification (curl + openssl)

Check every HTTPS endpoint the pipeline exposes. All should return `200` (or `404` for `localhost:4000` which is the API root — that is expected):

```bash
CA=/tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
for url in \
  https://localhost:4322 \
  https://localhost:8787/api/auth/availability \
  https://localhost:3001 \
  https://localhost:3002 \
  https://localhost:4100/health \
  https://localhost:3003 \
  https://localhost:4200/health \
  https://localhost:8000; do
  code=$(curl --cacert "$CA" -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 "$url" 2>/dev/null || echo ERR)
  printf "%-50s %s\n" "$url" "$code"
done
```

Then confirm the live cert issuer still matches your imported CA:

```bash
# Fingerprint of the CA you imported
openssl x509 -in /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  -noout -fingerprint -sha256 -subject

# Fingerprint of what the server is currently serving (issuer line must match above)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

**Expected results:**
- All `curl` lines return `200` (except port `4000` which returns `404` — the root path is intentionally empty)
- The `Issuer` CN in the served cert matches the `Subject` CN of your imported CA: both should be `CN=Track Binocle Local Development CA`
- If `curl` returns `ERR` for a port, that service may not be started yet — check `docker compose ps`

---

## Troubleshooting

### ERR_CERT_AUTHORITY_INVALID / SEC_ERROR_UNKNOWN_ISSUER

The browser does not trust the CA signing the served certificate. Work through this checklist:

1. **Compare fingerprints** (see [diagnosis section](#how-to-diagnose-which-ca-the-browser-is-seeing)). The issuer fingerprint of the live cert must match the CA you imported. If they differ, you imported the wrong CA.
2. **Confirm which process owns port 4322** (see [step 2](#2-identify-what-owns-port-4322)). The server may be a different proxy or VM than you expect.
3. **Confirm the CA was actually imported** — re-run the import helper with `certutil` in `PATH` and check the output for "Trusted" lines.
4. **Fully quit and restart the browser** after every import attempt.

---

### Chrome trust lost (exit code 3, certutil missing)

**Symptoms:** Chrome shows `net::ERR_CERT_AUTHORITY_INVALID` while Firefox (or a headless Chrome test with an ephemeral profile) may still succeed.

**Why this happens:**
- The import helper ran without `certutil` in `PATH` — it exits with code `3` and performs no NSS imports.
- A headless test used an ephemeral profile where the CA was added; the default Chrome profile (or a Flatpak-confined profile) did not receive the CA.
- Chrome installed as a Flatpak/Snap uses a confined per-app NSS store under `~/.var/app/.../data/pki/nssdb`; system CA and `~/.config` profile imports may not affect it.

**Diagnosis:**
```bash
# Is certutil available in PATH?
command -v certutil || echo 'certutil missing'

# If you previously extracted certutil to /tmp, check it explicitly
ls -l /tmp/track-binocle-cert-tools/root/usr/bin/certutil || true
file /tmp/track-binocle-cert-tools/root/usr/bin/certutil || true

# Detect Flatpak/Snap-wrapped Chrome (bwrap/zypak processes)
pgrep -af 'chrome|chromium' | sed -n '1,20p'

# Find all NSS DBs (includes Flatpak ~/.var/app locations)
find "$HOME/.config" "$HOME/.var/app" -type f -name cert9.db -print 2>/dev/null | sed -n '1,200p'

# Inspect the certificate the server is currently serving
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

**Fix:**

1. Get `certutil` (see [step 4](#4-get-certutil-without-sudo-no-install) for the no-sudo path):
```bash
mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools
apt-get download libnss3-tools || true
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)
dpkg-deb -x "$deb" root || true
export PATH="$(pwd)/root/usr/bin:$PATH"
command -v certutil || echo 'certutil still missing'
```

2. Re-run the import helper (searches both `~/.config` and `~/.var/app`):
```bash
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
export TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca
sh apps/baas/scripts/trust-localhost-cert.sh
```

3. Fully quit Chrome and reopen:
```bash
# Use the Flatpak app ID — avoids matching unrelated Electron/VS Code processes
flatpak kill com.google.Chrome 2>/dev/null || pkill -f '/app/extra/chrome' 2>/dev/null || true
# WARNING: do NOT use `pkill -f chrome` — the bare pattern matches any process
# whose args contain the string "chrome" (e.g. Claude Code's --no-chrome flag),
# which kills unrelated parent processes and terminates your shell session.
sleep 1
google-chrome https://localhost:4322/ & disown || true
```

4. Verify:
```bash
curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer
```

---

### Missing CSS / Styles in Chrome

**Symptoms:** The page HTML loads but Chrome renders an unstyled page or is missing backgrounds/visuals while Firefox looks correct.

**Common root causes:**
- Mixed-content: the HTTPS page tries to load assets over HTTP; browsers block insecure subresources.
- Dev-server assets (`/src/...` or `/@vite/client`) are not proxied or fail to load, so runtime CSS injection never runs.
- A service worker returns stale or broken cached responses.
- A browser extension or profile corruption interferes with CSS or runtime JS.
- CSP headers forbid loading remote modules or the proxy rewrites content-type.

**Quick checks in DevTools:**
- **Console**: look for `Mixed Content`, `Refused to execute script`, `Refused to apply style`, `Failed to load module script`, or service-worker fetch errors.
- **Network tab**: filter by `JS`, `CSS`, `Font` — look for `404`, `0` (blocked), or failed requests.
- **Application → Service Workers**: unregister any service worker and hard-refresh.

**Immediate test steps:**
```bash
# 1) Ephemeral profile (disables extensions) — if this renders correctly, it's profile/extension related
google-chrome --user-data-dir=/tmp/chrome-test-profile \
  --no-first-run --disable-extensions https://localhost:4322

# 2) Quick incognito test
google-chrome --incognito https://localhost:4322

# 3) Check whether a module endpoint returns the expected content type
/usr/bin/curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  -I https://localhost:4322/src/styles/main.scss
```

**Diagnosis → fix:**

| What DevTools shows | Root cause | Fix |
|---|---|---|
| Ephemeral profile renders correctly | Profile / extension / cached SW | Disable extensions (`--disable-extensions`), clear cache, or create a new profile |
| `Mixed Content` for `http://localhost:*` assets | HTTPS page loading HTTP assets | Configure dev proxy to serve assets over HTTPS, or change asset URLs to `https://` |
| `Failed to load module script` / CSP violation | Wrong MIME type or CSP too strict | Serve module scripts as `text/javascript`; update CSP to allow the dev host |
| Service worker returns stale markup | Stale SW cache | Unregister SW from DevTools → Application → Service Workers, then refresh |
| Flatpak/Snap Chrome, profile path unclear | Wrong profile being inspected | Check `~/.var/app/com.google.Chrome/` — the helper imports into these locations when `certutil` is available |

---

### Snap / Flatpak browsers

Snap and Flatpak packages run in a confined sandbox. The host CA store and `~/.config` profile directories may not be visible to the confined process.

**Flatpak Chrome (`com.google.Chrome`):**
- NSS DB: `~/.var/app/com.google.Chrome/data/pki/nssdb/cert9.db`
- The helpers import into this path when `certutil` is available.

**Flatpak Firefox (`org.mozilla.firefox`):**
- The script expects the profile at `~/.var/app/org.mozilla.firefox/.mozilla/firefox/` — but on some systems (42 school machines confirmed) it is actually at `~/.var/app/org.mozilla.firefox/config/mozilla/firefox/`.
- Use the `find`-based loop in [Flatpak profile path detection issue](#flatpak-profile-path-detection-issue) to import reliably regardless of the actual path.
- To manually confirm the path: `find ~/.var/app/org.mozilla.firefox -name cert9.db 2>/dev/null`

If per-app imports fail, the system-wide install (`sudo update-ca-certificates`) is the most reliable path for Chrome/Electron. Firefox Flatpak must be handled via its own NSS database; system CA trust does not cross the Flatpak sandbox boundary for Firefox.

---

### Gotchas & tips

- **Wrong CA imported**: always compare fingerprints (served cert issuer vs the CA file you're about to import) before trusting the import worked.
- **`certutil` missing**: use `apt-get download` + `dpkg-deb -x` to extract a usable `certutil` into `/tmp` without `sudo` (see [step 4](#4-get-certutil-without-sudo-no-install)).
- **`make certs-trust-browser-host` fails**: set `TRACK_BINOCLE_BROWSER_HOST=user@host` and `TRACK_BINOCLE_BROWSER_HOST_PORT=port` and rerun.
- **Snap/Flatpak Firefox**: the helper touches multiple profile locations. Fully quit the browser and reopen after import.
- **Chrome / Electron**: most Chromium builds on Linux use the OS CA store (`update-ca-certificates`). Per-profile NSS import alone may not be enough; use `make certs-trust-system` (requires `sudo`).
- **Architecture mismatch**: if you extracted `certutil` from a `.deb`, confirm it matches your host architecture: `file $(pwd)/root/usr/bin/certutil`.
- **NSS DB format**: use `sql:` prefix with `certutil -d` to target the modern `cert9.db` format.

---

## Copy-paste Cheat Sheet

**This is the exact sequence verified to work on a 42 school machine with Flatpak Firefox and Chrome, starting from a completely fresh state.**

Run every block in order. Each block has a clear goal and expected output so you know whether to continue or stop and diagnose.

> **Reboot note:** The NSS imports (steps 3–4) survive reboots because they live in `$HOME`. The CA file and `certutil` binary in `/tmp` do **not** survive reboots. After a reboot you only need to redo steps 1–2 to restore those temp files — the browser trust is still in place unless `make certs` was re-run on the VM (which generates a new CA).

---

```bash
# ============================================================
# STEP 0 — Orient yourself
# Expected: your host name (e.g. c2r19s4.42madrid.com), not b2b
# ============================================================
hostname && whoami && pwd

# Confirm the SSH tunnel to b2b is active (provides the port 4322 forward)
ps -eo pid,comm,args | grep 'ssh b2b' | grep -v grep \
  || echo "WARNING: ssh b2b not running — start it before continuing"
```

If `ssh b2b` is not listed, open a terminal and run `ssh b2b` (leave it open), or:
```bash
ssh -N -f b2b   # background, no shell
```

---

```bash
# ============================================================
# STEP 1 — Inspect the live cert and compare with the VM CA
# Goal: confirm you have the right CA before copying anything
# ============================================================

# 1a. What cert is localhost:4322 actually serving right now?
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
# Note the sha256 Fingerprint and Issuer CN.

# 1b. Get the VM CA fingerprint via SSH (no file transfer yet)
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "openssl x509 -in /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem \
   -noout -fingerprint -sha256 -subject -dates"
# The sha256 Fingerprint here must match the Issuer fingerprint from 1a.
# If they differ, port 4322 is served by a different CA — read the Docker
# container inspection section before continuing.
```

---

```bash
# ============================================================
# STEP 2 — Copy the VM CA to your host (public cert only)
# Goal: get the CA file into /tmp so certutil can import it
# ============================================================

mkdir -p /tmp/track-binocle-b2b-ca

ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" \
  | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

# Confirm the file arrived intact
openssl x509 -in /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  -noout -fingerprint -sha256 -subject -dates
# Fingerprint must match what step 1b showed.

# Verify the full TLS chain: the VM CA must sign the live cert
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost \
  </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem "$tmp_cert" \
  && echo "Chain OK — right CA" || echo "MISMATCH — wrong CA, stop here"
rm -f "$tmp_cert"
```

---

```bash
# ============================================================
# STEP 3 — Get certutil without sudo
# Goal: extract the certutil binary from the libnss3-tools .deb
# into /tmp (no install, no sudo required)
# ============================================================

mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools

# Downloads the .deb only — no install. On 42 school you may see:
#   W: Unable to read /etc/apt/preferences.d/mozilla - open (13: Permission denied)
# That warning is harmless; the download still succeeds.
apt-get download libnss3-tools 2>/dev/null || true

deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)
if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$deb" root
  export PATH="$(pwd)/root/usr/bin:$PATH"
else
  echo "ERROR: .deb not found or dpkg-deb missing"
fi

# Must print a path — if it prints nothing, stop and read the certutil section
command -v certutil
```

---

```bash
# ============================================================
# STEP 4 — Import the CA into every NSS database
# Goal: make Firefox and Chrome trust the CA
#
# The find-based approach catches Flatpak paths that the repo
# helper misses (confirmed on 42 school: Firefox Flatpak stores
# its profile under config/mozilla/firefox/, not .mozilla/firefox/)
# ============================================================

export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
CA=/tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
NICK="Track Binocle Local Development CA"

find "$HOME/.mozilla" "$HOME/.config" "$HOME/.var/app" "$HOME/.pki" \
  -type f -name cert9.db -print 2>/dev/null \
  | while IFS= read -r cert_db; do
      dir="$(dirname "$cert_db")"
      echo "Importing into: $dir"
      certutil -A -d "sql:$dir" -n "$NICK" -t "C,," -i "$CA" \
        && echo "  OK" || echo "  FAILED (may already exist — check with certutil -L)"
    done
```

---

```bash
# ============================================================
# STEP 4b — Verify every import actually took effect
# Expected: every line says TRUSTED
# ============================================================

find "$HOME/.mozilla" "$HOME/.config" "$HOME/.var/app" "$HOME/.pki" \
  -type f -name cert9.db -print 2>/dev/null \
  | while IFS= read -r cert_db; do
      dir="$(dirname "$cert_db")"
      result=$(certutil -L -d "sql:$dir" -n "$NICK" 2>/dev/null | grep -c "Trusted CA" || true)
      printf "%-70s %s\n" "$dir" \
        "$([ "${result:-0}" -gt 0 ] && echo 'TRUSTED ✓' || echo 'NOT FOUND — import failed')"
    done

# On 42 school with Flatpak Firefox + Chrome you should see 4 lines:
#   ~/.pki/nssdb                                                    TRUSTED ✓
#   ~/.var/app/com.google.Chrome/data/pki/nssdb                     TRUSTED ✓
#   ~/.config/mozilla/firefox/<profile>                             TRUSTED ✓
#   ~/.var/app/org.mozilla.firefox/config/mozilla/firefox/<profile> TRUSTED ✓
```

---

```bash
# ============================================================
# STEP 5 — Restart browsers (required — trust is cached in-process)
# ============================================================

# Kill any running Firefox (Flatpak and system installs)
pkill -x firefox-bin 2>/dev/null || true
pkill -x firefox 2>/dev/null || true
pkill -TERM -f 'org.mozilla.firefox' 2>/dev/null || true
# Kill any running Chrome (Flatpak) — use the app ID to avoid matching unrelated
# Electron/VS Code processes. Do NOT use `pkill -f chrome` (bare pattern):
# it matches any process whose args contain "chrome" (e.g. Claude Code --no-chrome)
# and kills your shell session.
flatpak kill com.google.Chrome 2>/dev/null || pkill -f '/app/extra/chrome' 2>/dev/null || true

# Confirm nothing is left running
pgrep -af 'firefox|firefox-bin|chrome|chromium' 2>/dev/null | grep -v grep || echo "All browsers closed"

# Relaunch (pick whichever you use)
firefox https://localhost:4322/ >/tmp/track-binocle-firefox.log 2>&1 & disown
# google-chrome https://localhost:4322/ >/dev/null 2>&1 & disown
```

---

```bash
# ============================================================
# STEP 6 — Final verification: all app endpoints must return 200
# ============================================================

CA=/tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
for url in \
  https://localhost:4322 \
  https://localhost:8787/api/auth/availability \
  https://localhost:3001 \
  https://localhost:3002 \
  https://localhost:4100/health \
  https://localhost:3003 \
  https://localhost:4200/health \
  https://localhost:8000; do
  code=$(curl --cacert "$CA" -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 3 "$url" 2>/dev/null || echo ERR)
  printf "%-50s %s\n" "$url" "$code"
done

# Note: localhost:4000 (osionos bridge API root) returns 404 — that is expected.
# ERR means the service is not started; run: docker compose ps
```

---

```bash
# ============================================================
# OPTIONAL: system-wide install (sudo)
# Needed for VS Code, Electron apps, and some Chrome builds
# that read the OS CA store instead of per-profile NSS DBs
# ============================================================
sudo cp /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem \
  /usr/local/share/ca-certificates/track-binocle-local-ca.crt \
  && sudo update-ca-certificates
```

---

## References

- [Certificate Authority overview — Wikipedia](https://en.wikipedia.org/wiki/Certificate_authority)
- [NSS (Mozilla) documentation](https://firefox-source-docs.mozilla.org/security/nss/index.html)
- [Chromium security — how Chrome evaluates certificates](https://www.chromium.org/Home/chromium-security)
- [Debian `update-ca-certificates` manpage](https://manpages.debian.org/unstable/ca-certificates/update-ca-certificates.8.en.html)
- [`apt-get` manual (download subcommand)](https://manpages.debian.org/unstable/apt/apt-get.8.en.html)
- [`dpkg-deb` manual (extract .deb)](https://manpages.debian.org/unstable/dpkg/dpkg-deb.1.en.html)
- [Flatpak sandbox permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html)
- [Snap security and confinement](https://snapcraft.io/docs/security)
