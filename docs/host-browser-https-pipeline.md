# Host Browser HTTPS Pipeline

Track Binocle serves the developer apps through the Docker `local-https-proxy` service. The proxy terminates HTTPS with the project-owned local CA and forwards plain HTTP to the containers inside the Docker network.

## Canonical Host URLs

Use the URLs printed by `make showcase`. The primary website URL is:

```text
https://localhost:4322
```

The proxy also exposes these HTTPS ports on the VM/host loopback interface:

```text
3001 osionos app
3002 Mail
3003 Calendar
4000 osionos bridge
4100 Mail bridge
4200 Calendar bridge
4322 website
8000 BaaS gateway
8787 auth gateway
18200 Vault
```

If a browser or port-forwarding UI opens `http://localhost:4322`, Nginx redirects it to `https://localhost:4322`. A raw `400 The plain HTTP request was sent to HTTPS port` means the proxy is running an old config; rerun `make up` or recreate `local-https-proxy`.

## Fresh Start Path

From the repository root, run:

```bash
make all
```

The pipeline must:

1. Generate `apps/baas/certs/track-binocle-local-ca.pem` and `apps/baas/certs/localhost.pem`.
2. Trust the CA locally through `make certs-trust-local`.
3. Try to trust the browser host through `make certs-trust-browser-host` when a remote/forwarded browser route is detectable.
4. Build and start the Docker services.
5. Verify HTTPS endpoints with `make healthcheck`.

`make healthcheck` also verifies that accidental plain HTTP on the website port redirects to HTTPS.

When `make` runs inside a VirtualBox NAT VM whose default gateway is `10.0.2.2`, it exports `TRACK_BINOCLE_BIND_ADDR=0.0.0.0` so the VM Docker proxy can be reached through VirtualBox port forwards. Normal host runs keep `TRACK_BINOCLE_BIND_ADDR=127.0.0.1`.

## VM-Side Checks

Check the proxy and published ports:

```bash
docker compose ps local-https-proxy
ss -ltnp '( sport = :4322 or sport = :3001 or sport = :3002 or sport = :3003 )'
```

Inside a VirtualBox NAT VM, the proxy ports must show `0.0.0.0:<port>` or `:::<port>` in `docker compose ps`; `127.0.0.1:<port>` is only reachable from inside the VM and will reset host-browser connections through NAT.

Forward the host browser ports to the VM once per VM:

```bash
for port in 3001 3002 3003 4000 4100 4200 4322 8000 8787 18200; do
  VBoxManage controlvm debian natpf1 "track-binocle-$port,tcp,,$port,,$port"
done
```

Add `8025` the same way when the host browser also needs the Mailpit inbox.

Check the CA and live proxy certificate:

```bash
make certs-doctor
```

Expected output includes:

```text
[certs] Linux system CA store has the current Track Binocle CA.
[certs] local HTTPS proxy serves the current Track Binocle CA on https://localhost:4322
[certs] plain HTTP on localhost:4322 redirects to HTTPS
```

Check the redirect manually:

```bash
curl -i http://localhost:4322/ | sed -n '1,8p'
```

Expected status:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://localhost:4322/
```

Check HTTPS manually:

```bash
curl --cacert apps/baas/certs/track-binocle-local-ca.pem -fsS https://localhost:4322 >/dev/null
```

## Host Browser Trust

When the browser runs on the same Linux machine as Docker, `make certs-trust-system` imports the CA into the Linux system trust store and browser NSS stores.

Firefox needs one extra compatibility step, handled by the trust helper: each regular, Snap, and Flatpak Firefox profile gets `security.enterprise_roots.enabled=true` in `user.js`. Fully quit every Firefox process after CA import, then reopen the HTTPS URL.

When the browser runs outside the VM through VS Code Remote SSH, SSH tunneling, or another port forwarder, the host browser has its own trust store. Configure a back-to-host SSH route when auto-detection cannot reach it:

```bash
TRACK_BINOCLE_BROWSER_HOST=user@host make certs-trust-browser-host
```

Use a non-default SSH port like this:

```bash
TRACK_BINOCLE_BROWSER_HOST=user@host \
TRACK_BINOCLE_BROWSER_HOST_PORT=2222 \
make certs-trust-browser-host
```

Make host trust mandatory during onboarding checks:

```bash
TRACK_BINOCLE_BROWSER_HOST_REQUIRED=1 make certs-trust-browser-host
```

## VS Code Forwarded Ports

Prefer the canonical URLs printed by `make showcase`. A random forwarded URL such as `https://localhost:4323` can be owned by VS Code rather than Docker Compose. If that URL serves a stale editor-side certificate, close and reopen the forwarded port or restart VS Code, then use the canonical HTTPS URL again.

Compare ports with:

```bash
for port in 4322 4323; do
  echo "port=$port"
  timeout 5 openssl s_client -connect localhost:$port -servername localhost </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 -ext authorityKeyIdentifier 2>/dev/null || true
done
```

<<<<<<< Updated upstream
`4322` must be signed by the current `apps/baas/certs/track-binocle-local-ca.pem`. A mismatched forwarded port is outside the Docker proxy and should not be used as the source of truth.
=======
`4322` must be signed by the current `apps/baas/certs/track-binocle-local-ca.pem`. A mismatched forwarded port is outside the Docker proxy and should not be used as the source of truth.
>>>>>>> Stashed changes
