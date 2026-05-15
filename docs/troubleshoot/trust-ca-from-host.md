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

## Chrome / Chromium — make Chrome trust the Track Binocle CA

Chrome on Linux typically relies on the system CA store (Debian/Ubuntu: `update-ca-certificates`) and/or per-profile NSS databases for Chromium-based browsers. The repo includes a small helper that attempts to import the VM CA into Chromium/Chrome profile NSS DBs and advises the system-level install.

Run this one-liner (adjust the paths if you used different temp dirs):

```bash
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH \
  sh apps/baas/scripts/trust-chrome-cert.sh
```

What the helper does:
- Attempts to import the CA into any existing `cert9.db` NSS DBs under `~/.config/google-chrome`, `~/.config/chromium`, `~/.config/BraveSoftware`, etc.
- Prints a short reminder and the exact `sudo` command to install the CA into the system store if you want global trust (Chrome/Electron):

```bash
sudo cp /path/to/track-binocle-local-ca.pem /usr/local/share/ca-certificates/track-binocle-local-ca.crt && sudo update-ca-certificates
```

After running the helper or the system install, fully quit every Chrome/Chromium process and reopen the page at `https://localhost:4322`.

If Chrome is installed as a Snap/Flatpak bundle, extra steps may be required because those packages can be confined from the host CA store — consult the Snap/Flatpak packaging docs or re-run the helper on the actual host where the browser runs.

If problems persist, re-check fingerprints (step 4) and confirm which process owns port 4322 (step 5); the site may still be served by a VM/proxy using a different CA.


---

If you want I can:
- Save this markdown to `docs/troubleshoot/local-https-repro.md` in the repo, or
- Run the "quick recommended sequence" now (if you want me to re-run these steps). Which do you prefer?

---

## Chrome trust lost — diagnosis, root causes, and fix

Symptoms
- Chrome shows `net::ERR_CERT_AUTHORITY_INVALID` for `https://localhost:4322` while Firefox (or a headless Chrome test with an ephemeral profile) may still succeed.

Why this happens (exact causes observed)
- The import helper was run without `certutil` available in `PATH` — the helper exits with code `3` and performs no NSS imports. (This is the earlier observed `exit code 3`.)
- A successful headless test often uses an ephemeral profile where the CA was added locally; the default Chrome profile (or the Flatpak/Snap confined profile) did not receive the CA.
- Chrome installed as a Flatpak/Snap can use a confined per-app NSS store under `~/.var/app/.../data/pki/nssdb` (or similar), so system CA or `~/.config` profile imports may not affect it.
- Browser processes cache trust state in-process; imports won't take effect until Chrome is fully quit and restarted.

Diagnosis commands (run these to confirm the cause)
```bash
# is certutil available in PATH?
command -v certutil || echo 'certutil missing'

# if you previously extracted certutil to /tmp, check it explicitly
ls -l /tmp/track-binocle-cert-tools/root/usr/bin/certutil || true
file /tmp/track-binocle-cert-tools/root/usr/bin/certutil || true

# detect Flatpak/Snap-wrapped Chrome (bwrap/zypak processes)
pgrep -af 'chrome|chromium' | sed -n '1,20p'

# find NSS DBs under common locations (includes Flatpak ~/.var/app)
find "$HOME/.config" "$HOME/.var/app" -type f -name cert9.db -print 2>/dev/null | sed -n '1,200p'

# inspect the certificate the browser/server is currently serving
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```

Quick fix (reproducible, no-sudo path)
1) Ensure `certutil` is available (no-sudo extraction if you can't apt-install):
```bash
mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools
apt-get download libnss3-tools || true
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)
dpkg-deb -x "$deb" root || true
export PATH="$(pwd)/root/usr/bin:$PATH"
command -v certutil || echo 'certutil still missing'
```

2) Re-run the import helper (it searches both `~/.config` and `~/.var/app` for profiles):
```bash
export PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH
export TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca
sh apps/baas/scripts/trust-localhost-cert.sh
```
Expected helpful output (example):
```
Trusted local CA in NSS database: /home/you/.pki/nssdb
Trusted local CA in existing NSS database: /home/you/.var/app/com.google.Chrome/data/pki/nssdb
Done. Fully quit and restart Chrome/Chromium/Firefox, then reopen the dev URL.
```

3) Fully quit Chrome (Flatpak) and re-open the page:
```bash
# quit processes (graceful/forceful if necessary)
pkill -f '/app/extra/chrome' || pkill -f chrome || true
sleep 1
google-chrome https://localhost:4322/ & disown || true
```

4) Verify with curl/openssl:
```bash
curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer
```

Alternative: system-wide install (requires sudo)
```bash
sudo cp /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem /usr/local/share/ca-certificates/track-binocle-local-ca.crt
sudo update-ca-certificates
```

Flatpak / Snap notes
- Flatpak-wrapped Chrome stores runtime data under `~/.var/app/com.google.Chrome/` and is sandboxed; the helper imports into these locations when `certutil` is available.
- If per-app imports fail, prefer the system-wide install (sudo), or consult Flatpak docs for adding host CA into the Flatpak runtime.

Why this exact situation happened here
- You ran the Chrome helper without `certutil` in `PATH`, so it exited early (exit code 3) and didn't import the CA into Chrome's NSS store. A headless-profile test succeeded because you had created an ephemeral profile and imported the CA there; the running Flatpak Chrome default profile had no CA. Re-running the helper with `certutil` in `PATH` (or installing `libnss3-tools`) and restarting Chrome fixes the issue.

Add this to the earlier section so future readers see the root cause and exact recovery steps.

## Missing CSS / Styles in Chrome — diagnosis & fixes

Symptoms
- Page HTML loads but Chrome shows an unstyled page or missing backgrounds/visuals while Firefox looks correct.

Common root causes
- Mixed-content or blocked module/script requests (HTTP -> HTTPS) preventing runtime style injection.
- Dev-server assets (Vite `/src/...` or `/@vite/client`) not proxied or failing to load, so runtime CSS injection doesn't run.
- Service worker returning stale or broken responses (cached HTML without runtime assets).
- Browser extension or profile corruption interfering with CSS or runtime JS.
- GPU / rendering quirks (rare) or experimental Chrome flags.

Quick checks (DevTools)
- Open DevTools (F12) → Console: look for errors like `Mixed Content`, `Refused to execute script`, `Refused to apply style`, `Failed to load module script`, or service-worker fetch errors.
- Network tab: filter `JS`, `CSS`, `Font` and look for `404`, `0`, or blocked requests.
- Application → Service Workers: unregister any SW and refresh.

Immediate repro / test steps
```bash
# 1) Try an ephemeral profile (disables extensions) — if this renders correctly, it's profile/extension related
google-chrome --user-data-dir=/tmp/chrome-test-profile --no-first-run --disable-extensions https://localhost:4322

# 2) Try incognito (quick test)
google-chrome --incognito https://localhost:4322

# 3) Hard refresh to bypass caches
# (in Chrome: Ctrl+Shift+R) or via command line open a new profile as above.

# 4) Check the module endpoint the page expects (example: Vite-style entry for styles)
/usr/bin/curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -I https://localhost:4322/src/styles/main.scss

# 5) If a service worker is registered, unregister it in DevTools and refresh.
```

If ephemeral profile fixes it
- Root cause: profile, extension, or cached service worker. Disable extensions, clear the profile cache, or create a new profile. To debug extensions, re-open normal profile with `--disable-extensions` then enable them one-by-one.

If DevTools shows `Mixed Content` for http://localhost:* assets
- Root cause: the page loaded over HTTPS attempts to load assets over HTTP. Browsers block insecure subresources.
- Fix: configure your dev proxy (nginx or the tunnel) to proxy dev-server assets over HTTPS, or serve the site and assets on the same HTTPS origin. Alternatively change asset URLs to protocol-relative (`//`) or `https://`.

If DevTools shows `Failed to load module script` or `Refused to execute script` (CSP)
- Root cause: CSP forbids loading remote modules or the proxy rewrote content-type.
- Fix: serve module scripts with correct mime-type (text/javascript), or update CSP headers to allow the dev host while developing.

If service worker is serving stale markup
- Unregister the SW from DevTools → Application → Service Workers and refresh. Consider versioning SW responses during development.

If it's a Flatpak / Snap Chrome build
- Confirm the profile path you inspected is the one the running Chrome process uses (look under `~/.var/app/com.google.Chrome/`); the helper imports into these locations when `certutil` is available.

Add these checks to your troubleshooting flow when styles disappear in Chrome. If you want, I can append a short checklist entry to `docs/troubleshoot/trust-ca-from-host.md` (done) and create a small `scripts/check-page-assets.sh` helper to automate the HTTP checks — should I add that script?


## Agent notes: plan & appendix (reproducible details and reasoning)

- **Plan delivered:** a short plan and a reproducible appendix were prepared to make Chrome and Firefox trust the VM CA for `https://localhost:4322`.

### Appendix: Play-by-play & reproducible recipe (Chrome + Firefox)

Goal
- Make the host browser trust the CA that signs the certificate served at https://localhost:4322 (often served from a VM/tunnel).

Assumptions
- You have SSH access to the VM alias `b2b`.
- Repo root: /sgoinfre/students/dlesieur/ft_transcendence (commands assume repo-relative paths).
- You may not have `certutil` or `sudo`; this recipe includes a no-sudo fallback.

Why this flow (short logic)
- Browsers trust a certificate only when the chain roots to a CA in their trust store.
- If localhost:4322 is forwarded from a VM, the served cert is signed by the VM CA — you must import that CA into the host browser store.
- Firefox uses NSS (per-profile cert9.db / enterprise roots pref). Chromium/Chrome on Linux uses either OS trust (update-ca-certificates) or profile NSS DBs.
- To avoid copying private keys, only copy the public CA PEM from the VM (base64 over SSH).
- If `certutil` is missing and you cannot install packages, extract it from the libnss3-tools .deb with dpkg-deb (no sudo).

Recipe — step-by-step (receipt)

1) Inspect local repo CA and the live served cert
- confirm repo CA fingerprint:
```bash
openssl x509 -in apps/baas/certs/track-binocle-local-ca.pem -noout -fingerprint -sha256 -subject -dates
```
- inspect the cert currently served on localhost:4322 (what the browser sees):
```bash
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```
- save & verify live cert against a CA file:
```bash
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem "$tmp_cert" || true
rm -f "$tmp_cert"
```
If fingerprints differ, the browser sees a different CA (likely the VM's CA).

2) Check whether port 4322 is forwarded from VM or served locally
```bash
ss -ltnp 'sport = :4322' || ss -ltnp | grep ':4322' || true
fuser -v 4322/tcp 2>&1 || true
command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:4322 -sTCP:LISTEN || true
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
ps -eo pid,user,comm,args | grep -E '4322|local-https-proxy|nginx|astro|node|ssh|socat' | grep -v grep || true
```
- If you see an active `ssh`/SSH-forward or a service on another host, treat port 4322 as forwarded.

3) If forwarded: find the VM CA path (on the VM)
```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  'printf "host=%s user=%s home=%s\n" "$(hostname)" "$(id -un)" "$HOME"; \
   find "$HOME" /sgoinfre/students/dlesieur -maxdepth 6 -path "*/apps/baas/certs/track-binocle-local-ca.pem" -print 2>/dev/null | head -20'
```
Common path: /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem

4) Copy VM CA to the host (public cert only)
```bash
mkdir -p /tmp/track-binocle-b2b-ca
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b \
  "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" \
  | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
openssl x509 -in /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -noout -fingerprint -sha256 -subject -dates
```
Do NOT copy private keys.

5) If `certutil` is missing (no-sudo extraction)
```bash
mkdir -p /tmp/track-binocle-cert-tools
cd /tmp/track-binocle-cert-tools
apt-get download libnss3-tools || true
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)
if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$deb" root
  export PATH="$(pwd)/root/usr/bin:$PATH"
fi
command -v certutil || true
```
Notes:
- `apt-get download` only downloads the .deb (no install).
- If apt/network blocked, fetch package another way or run the helper where certutil exists.

6) Import the VM CA into Firefox/NSS (per-user, no sudo)
```bash
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH \
  sh apps/baas/scripts/trust-localhost-cert.sh
```
- The helper will:
  - import into found Firefox profiles' NSS DBs (cert9.db),
  - set enterprise roots pref when relevant,
  - optionally print system-level instructions (requires sudo).

7) Verify the TLS chain locally (again)
```bash
tmp_cert=$(mktemp)
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null | openssl x509 -out "$tmp_cert"
openssl verify -CAfile /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem "$tmp_cert"
rm -f "$tmp_cert"
```
Expect `OK` if the copied CA matches the server cert issuer chain.

8) Chrome / Chromium — ephemeral profile test (no sudo)
```bash
certutil -N -d "sql:/tmp/chrome-profile-trust" --empty-password
certutil -A -d "sql:/tmp/chrome-profile-trust" \
  -n "Track Binocle Local Development CA" -t "C,," \
  -i /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
google-chrome --user-data-dir=/tmp/chrome-profile-trust --no-first-run \
  --headless --disable-gpu --dump-dom https://localhost:4322 || true
```
- If headless Chrome returns the DOM and exits 0, Chrome accepted the TLS chain for that profile.

9) Import CA into existing Chrome profiles (per-profile, no sudo)
```bash
find ~/.config -type f -name cert9.db -print0 2>/dev/null | xargs -0 -n1 dirname | sort -u | \
  while read -r profile_dir; do
    echo "Importing into $profile_dir"
    certutil -A -d "sql:$profile_dir" -n "Track Binocle Local Development CA" -t "C,," \
      -i /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem || true
  done
```
- After importing to any profile, fully quit Chrome/Chromium processes (see step 11) and re-open the browser with that profile.

10) System / global install for Chrome/Electron (requires sudo)
```bash
sudo cp /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem /usr/local/share/ca-certificates/track-binocle-local-ca.crt
sudo update-ca-certificates
```
- Rationale: many Chromium builds on Linux use the OS certificate store. This is needed for system-wide trust (Electron apps too).

11) Browser restart (required)
```bash
# quit Chrome / Firefox processes
pkill -f 'chrome|chromium' || true
pkill -f 'firefox|firefox-bin' || true
# confirm none running
pgrep -af 'chrome|chromium|firefox|firefox-bin' || true
# reopen browser
firefox https://localhost:4322/ & disown || true
google-chrome https://localhost:4322/ & disown || true
```
Why: browsers cache trust state in-process; imports won't affect running processes until restart.

12) Final verification (curl + openssl)
```bash
curl --cacert /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem -sS -o /dev/null -w 'https_4322=%{http_code}\n' https://localhost:4322/
timeout 5 openssl s_client -connect localhost:4322 -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 -issuer -subject -dates
```
Expect HTTP 200 from curl and matching issuer fingerprint.

13) Troubleshooting checklist & gotchas
- If you still see ERR_CERT_AUTHORITY_INVALID:
  - Re-check fingerprints (step 1) — the repo CA must match the served cert issuer.
  - Confirm which process owns port 4322 (step 2) — you may be hitting a different proxy/VM.
- If `certutil` was extracted from a .deb:
  - Ensure the extracted binary matches host arch (x86_64 vs arm).
  - Use `file $(pwd)/root/usr/bin/certutil`.
- Snap / Flatpak browsers:
  - Snap/Flatpak apps run confined and may not use the host CA store; either run the import inside the confined environment or use the per-profile import if the profile is visible to the runtime.
- NSS DB formats:
  - Modern NSS uses SQL DB format (`cert9.db` + `key4.db`). Legacy used DBM `cert8.db`. Use `sql:` prefix in `certutil` with `-d "sql:/path"`.
- Avoid copying private keys — only share public CA PEM.
- Always fully quit the browser after importing CA.

Representative commands I used during debugging (copy-paste)
```bash
# copy CA from VM
ssh -o BatchMode=yes -o ConnectTimeout=5 b2b "base64 -w0 /home/dlesieur/ft_transcendence/apps/baas/certs/track-binocle-local-ca.pem" | base64 -d > /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem

# extract certutil without sudo
apt-get download libnss3-tools
deb=$(ls libnss3-tools_*.deb 2>/dev/null | head -n1 || true)
dpkg-deb -x "$deb" root
export PATH="$(pwd)/root/usr/bin:$PATH"

# import into Firefox (repo helper)
TRACK_BINOCLE_CERT_DIR=/tmp/track-binocle-b2b-ca PATH=/tmp/track-binocle-cert-tools/root/usr/bin:$PATH \
  sh apps/baas/scripts/trust-localhost-cert.sh

# ephemeral Chrome profile test
certutil -N -d "sql:/tmp/chrome-profile-trust" --empty-password
certutil -A -d "sql:/tmp/chrome-profile-trust" -n "Track Binocle Local Development CA" -t "C,," -i /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem
google-chrome --user-data-dir=/tmp/chrome-profile-trust --no-first-run --headless --disable-gpu --dump-dom https://localhost:4322

# optional system install (sudo)
sudo cp /tmp/track-binocle-b2b-ca/track-binocle-local-ca.pem /usr/local/share/ca-certificates/track-binocle-local-ca.crt && sudo update-ca-certificates
```

References / web resources I consulted
- Certificate authority overview: https://en.wikipedia.org/wiki/Certificate_authority
- NSS (Mozilla/Firefox) docs: https://firefox-source-docs.mozilla.org/security/nss/index.html
- Chromium security / how Chrome treats certs: https://www.chromium.org/Home/chromium-security
- Debian/Ubuntu `update-ca-certificates` manpage: https://manpages.debian.org/unstable/ca-certificates/update-ca-certificates.8.en.html
- `apt-get` manual (download): https://manpages.debian.org/unstable/apt/apt-get.8.en.html
- `dpkg-deb` manual (extract .deb): https://manpages.debian.org/unstable/dpkg/dpkg-deb.1.en.html
- Flatpak sandbox/permissions (Snap/Flatpak confinement notes): https://docs.flatpak.org/en/latest/sandbox-permissions.html
- Snap security docs (snap confinement): https://snapcraft.io/docs/security

Where I placed this
- This appendix is appended here so the steps and rationale are preserved for reproducibility.

Next steps
- I can create a git patch / commit with this appended text. Say `yes` and I'll produce the patch and commit message.
