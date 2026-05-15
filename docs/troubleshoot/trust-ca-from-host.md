# Repro: Trust Track Binocle local HTTPS (https://localhost:4322)

Quick goal: ensure your browser trusts the CA that signs the certificate served on `https://localhost:4322` (may come from the VM/tunnel).

Prereqs / assumptions
- You have SSH access to the VM named `b2b` (the repo uses `b2b` as the SSH alias).
- You're working from the repo root (`/sgoinfre/students/dlesieur/ft_transcendence`) or can `cd` there.
- You may not have `certutil` or sudo; the playbook includes a no-sudo fallback.

---

## 1) Generate the local CA + server cert (repo helper)
```bash
# from repo root
bash apps/baas/scripts/generate-localhost-cert.sh
# (Makefile wrapper)
make certs
```

---

## 2) Trust the local CA in local browser stores (user-level)
```bash
# attempt user-level import (certutil required for NSS/Firefox import)
bash apps/baas/scripts/trust-localhost-cert.sh

# to install into the system CA store (requires sudo)
sudo bash apps/baas/scripts/trust-localhost-cert.sh --system

# Makefile targets
make certs-trust-local
make certs-trust-system   # system-level (sudo)
```

Note: If `certutil` is missing the script will still advise / try system install or tell you to install `libnss3-tools`.

---

## 3) Push CA to a remote browser host (when browser runs outside this VM)
```bash
# Auto-detects SSH client/gateway and tries to copy+import remotely
make certs-trust-browser-host
# or
bash apps/baas/scripts/trust-browser-host-ca.sh

# If auto-detect fails, specify the host and port explicitly:
TRACK_BINOCLE_BROWSER_HOST=user@host TRACK_BINOCLE_BROWSER_HOST_PORT=2222 make certs-trust-browser-host
```

If you cannot reach the browser host via SSH, copy the CA file manually (see step 5).

---

## 4) Inspect fingerprints and live certificate (important to compare CA -> served cert)
```bash
# Show repo/local CA fingerprint
openssl x509 -in apps/baas/certs/track-binocle-local-ca.pem -noout -fingerprint -sha256 -subject -dates

# Show the certificate currently served on localhost:4322 (what the browser sees)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates

# Save the live cert and verify it against a CA file
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem "$tmp_cert"
rm -f "$tmp_cert"
```

If fingerprints differ, the browser is seeing a different CA (common cause: SSH tunnel forwards a VM that has its own CA).

---

## 5) Diagnose which process / listener owns port 4322
```bash
# show listening socket
ss -ltnp 'sport = :4322' || true

# shallow checks for owner
fuser -v 4322/tcp 2>&1 || true
ps -eo pid,user,comm,args | grep -E '4322|local-https-proxy|nginx|astro|node|ssh|socat' | grep -v grep || true

# list containers and compose services
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed -n '1,80p'
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.State}}\t{{.Ports}}' 2>/dev/null || true

# fallback lsof/netstat if available
command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:4322 -sTCP:LISTEN || true
command -v netstat >/dev/null 2>&1 && netstat -ltnp 2>/dev/null | grep ':4322' || true
```

If you see an SSH agent or `ssh b2b` active and no Docker container for the proxy, the port is likely an SSH-forward to the VM.

---

## 6) If the port is forwarded from the VM: find the VM’s repo CA path
```bash
# run on your host (from VM) to locate the CA file in the VM checkout
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  'printf "host=%s user=%s home=%s\n" "$(hostname)" "$(id -un)" "$HOME"; find "$HOME" /sgoinfre/students/dlesieur -maxdepth 6 -path "*/apps/baas/certs/track-binocle-local-ca.pem" -print 2>/dev/null | head -20'
```

Common VM CA path found in this repo: `/home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem`

---

## 7) Copy the VM CA locally (safe, only public cert) and import it
```bash
# create temp dir locally
mkdir -p /tmp/track-binocle-b2b-ca

# copy via ssh+base64 (no private keys transferred)
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" \
  | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

# verify the CA file locally
openssl x509 -in /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -noout -fingerprint -sha256 -subject -dates

# import the VM CA into local Firefox/Chromium NSS using the repo helper (prefers certutil)
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca PATH="/tmp/track-binocle-cert-tools/root/usr/bin:$PATH" \
  sh apps/baas/scripts/trust-localhost-cert.sh
# or (if certutil exists globally)
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca sh apps/baas/scripts/trust-localhost-cert.sh
```

---

## 8) If `certutil` is missing: get `libnss3-tools` without sudo and extract `certutil` (no-install approach)
```bash
# create a temp workspace for the package and download .deb (no sudo needed)
mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools

# inspect candidate version (optional)
apt-cache policy libnss3-tools || true

# download the package archive (no install)
apt-get download libnss3-tools || true

# find the downloaded .deb robustly (avoid brittle wildcards)
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)

# if we found a .deb and dpkg-deb is present, extract certutil into a temp root
if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$deb" root
  export PATH="$(pwd)/root/usr/bin:$PATH"
else
  echo "warning: libnss3-tools .deb not found or dpkg-deb missing; certutil may be unavailable"
fi

# verify certutil is available now (may still be missing)
command -v certutil || true
```

Then re-run the import helper (example from step 7).

Notes:
- `apt-get download` only downloads .deb; no sudo required.
- If your environment restricts outbound apt or the mirror, download may fail.

## Assessing browser action:
import CA VM is now imported into the local NSS stores that firefox uses, and OpenSSL verifies the live `https://localhost:4322` certificate against that VM CA. Firefox is still running, though, so it may keep the old "unknown issuer" state until it is fully closed and reopened.
```bash
# After extracting or making `certutil` available (see step 8), run the helper
# ensure the helper uses the VM CA and the extracted certutil from /tmp (if used)
export TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
printf '[certs] Using certutil: %s\n' "$(command -v certutil)"
TRACK_BINOCLE_CERT_DIR="$TRACK_BINOCLE_CERT_DIR" PATH="$PATH" sh apps/baas/scripts/trust-localhost-cert.sh
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile "$TRACK_BINOCLE_CERT_DIR/track-binocle-local-ca.pem" "$tmp_cert"
rm -f "$tmp_cert"
```

---

## 9) Restart Firefox so NSS trust changes take effect
```bash
# try graceful termination first
cd /sgoinfre/students/dlesieur/ft_transcendence
pkill -x firefox-bin || true
pkill -x firefox || true
pgrep -af 'firefox|firefox-bin' || true
curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/

# if processes persist, force terminate
pkill -TERM -f '/usr/lib/firefox/firefox-bin' || true
pkill -TERM -f '/usr/lib/firefox/crashhelper' || true
pgrep -af 'firefox|firefox-bin' || true

# confirm no firefox running
pgrep -af 'firefox|firefox-bin' | sed -n '1,6p' || true; curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/

# relaunch Firefox on canonical URL
firefox https://localhost:4322/ >/tmp/track-binocle-firefox.log 2>&1 & disown
```

Important: Firefox caches trust state inside running processes; fully quitting before re-opening is required.

---

## 10) Final verification (curl + openssl)
```bash
# check HTTP status using the imported VM CA
curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/

# verify served cert fingerprint again
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

Expect a `200` from curl and that the served cert's issuer fingerprint matches the VM CA fingerprint.

---

## 11) Optional / follow-ups
```bash
# Check repo Makefile helpers
make certs-doctor

# Run the full pipeline (this may be heavy)
make all
```

---

## Quick recommended sequence to re-run the full trust flow (fast)
```bash
# generate local certs
make certs

# import locally (user-level or system-level if you have sudo)
make certs-trust-local

# if browser is on another host (remote or forwarded), try:
make certs-trust-browser-host

# verify local proxy
make certs-doctor
```

---

## Gotchas & tips
- If the browser shows `SEC_ERROR_UNKNOWN_ISSUER`, compare fingerprints — the served certificate may come from a different CA (VM vs checkout).
- If `certutil` is missing and you cannot `sudo`, use `apt-get download` + `dpkg-deb -x` to extract a usable `certutil` in `/tmp`.
- If `make certs-trust-browser-host` fails, set `TRACK_BINOCLE_BROWSER_HOST=user@host` and `TRACK_BINOCLE_BROWSER_HOST_PORT=port` and rerun.
- For Snap/Flatpak Firefox, the helper touches multiple profile locations; ensure you fully quit the browser and reopen after import.
- To update Chrome/Electron trust you likely need `make certs-trust-system` (sudo required).

---

If you want I can:
- Save this markdown to `docs/troubleshoot/local-https-repro.md` in the repo, or
- Run the "quick recommended sequence" now (if you want me to re-run these steps). Which do you prefer?
