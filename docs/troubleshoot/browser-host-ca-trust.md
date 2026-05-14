# Browser Host CA Trust Over SSH

When the Track Binocle stack is opened through VS Code Remote SSH, an SSH tunnel, or another forwarded localhost URL, the browser may run on a different machine than the Debian VM that ran `make all`. In that case the VM can trust the local CA correctly, but the browser host can still show `net::ERR_CERT_AUTHORITY_INVALID`.

`make all` runs `make certs-trust-browser-host` after local CA trust. This target tries to detect the browser host from `SSH_CONNECTION` and the VM default gateway, then uses SSH/SCP to copy the local CA and trust helper to that host.

## Automatic Path

The automatic helper tries:

```bash
make certs-trust-browser-host
```

It uses these defaults:

```text
host candidates: SSH_CONNECTION client host, then default gateway
user candidates: current VM user
port candidates: 22, 2222
remote directory: ~/.cache/track-binocle/certs
```

If a candidate is reachable with SSH key authentication, the helper copies:

```text
apps/baas/certs/track-binocle-local-ca.pem
apps/baas/scripts/trust-localhost-cert.sh
```

Then it runs the trust import on the browser host:

```bash
TRACK_BINOCLE_CERT_DIR=.cache/track-binocle/certs \
  sh .cache/track-binocle/certs/trust-localhost-cert.sh --system
```

## Configure A Non-Default Route

If auto-detection cannot reach the browser host, provide the host route explicitly:

```bash
TRACK_BINOCLE_BROWSER_HOST=user@host make certs-trust-browser-host
```

Use a non-standard SSH port:

```bash
TRACK_BINOCLE_BROWSER_HOST=user@host \
TRACK_BINOCLE_BROWSER_HOST_PORT=2222 \
make certs-trust-browser-host
```

Try multiple users or ports during auto-detection:

```bash
TRACK_BINOCLE_BROWSER_HOST_USERS="alice dlesieur" \
TRACK_BINOCLE_BROWSER_HOST_PORTS="22 2222 8022" \
make certs-trust-browser-host
```

Make failure fatal during onboarding checks:

```bash
TRACK_BINOCLE_BROWSER_HOST_REQUIRED=1 make certs-trust-browser-host
```

Disable browser-host trust when the browser runs inside the VM or trust is managed by IT:

```bash
TRACK_BINOCLE_BROWSER_HOST_TRUST=skip make all
```

## Prepare The Browser Host

The browser host must allow SSH from the VM and accept a key for the browser-host user.

1. Enable OpenSSH server on the machine that runs the browser.
2. Add the VM public key to that user's `~/.ssh/authorized_keys` on the browser host.
3. Make sure the browser host firewall allows the chosen SSH port from the VM network.
4. Test from the VM:

```bash
ssh -o BatchMode=yes user@host 'uname -a'
```

5. Run:

```bash
TRACK_BINOCLE_BROWSER_HOST=user@host make certs-trust-browser-host
```

The remote trust helper may ask for sudo on the browser host the first time it updates the system CA store. Later runs are idempotent and skip sudo when the installed CA already matches the current project CA.

## Diagnose Failures

Show the VM's detected SSH client and gateway:

```bash
printf 'SSH_CONNECTION=%s\n' "$SSH_CONNECTION"
ip route show default
```

Check whether the browser host exposes SSH:

```bash
for port in 22 2222 8022; do
  timeout 3 sh -c "</dev/tcp/HOST/$port" >/dev/null 2>&1 && echo "HOST:$port open" || echo "HOST:$port closed"
done
```

Check VM-side certificate trust:

```bash
make certs-doctor
curl -fsS https://localhost:4322 >/dev/null
```

If VM-side trust works but the forwarded browser still warns, the browser host trust store is the missing piece. Configure the SSH route above or import `apps/baas/certs/track-binocle-local-ca.pem` manually into the OS/browser trust store on the browser host.
