# 0074. `/storage/v1` is sandboxed at the app-origin edge, and the VM storage-router guard is on

- Status: accepted. Item 1 PROCEED-WITH-CONDITIONS SG-1–SG-7 (not applied yet). Item 2
  PROCEED-WITH-CONDITIONS SG-8–SG-14 (on groot develop c3972a27, not live). Item 3 PROCEED (SG-15).
  Rejected: loading the whole prod overlay on the VM, `Content-Disposition` at the edge, and
  deleting the Kong minio route inside this unit.
- Date: 2026-11-22
- Deciders: devil (ruling); groot edge and VM operator (live with it)

## Context

grobase's storage-router has an active-content guard (`STORAGE_ACTIVE_CONTENT_GUARD_ENABLED`).
When it is on, the router sends nosniff on every object. For HTML/SVG-like types it also sends
CSP `sandbox` and `attachment`, and it signs presigned GETs of those types with an attachment
disposition. The facts below were checked on the live VM, grobase e71ab899, on 2026-11-22.

- **The guard is off live.** The compose file passes the key bare (`app-services.yml:242`), so it
  resolves to empty. Only `docker-compose.prod.yml:135` sets "1", and the VM chain
  (`docker-compose.yml` plus `docker-compose.remote-access.yml`, project `mini-baas`) does not load
  that overlay.
- **The guard never runs on most of `/storage/v1`.** Kong sends sign/object/list/bucket to the
  router. Every other `/storage/v1/*` goes straight to `minio:9000` with `strip_path`
  (`kong.yml:327-331`).
- **A link click cannot reach the router download.** Identity comes from headers only, and a
  top-level navigation carries none, so the router answers 401.
- **The browser does not use `/storage/v1`.** osionos media goes through the bridge
  (`/api/media/*`, read server-side). `grep` finds no `storage/v1` in osionos `src/`, mail,
  calendar or drawnosaurus.
- **No bucket is public (U1, measured).** Anonymous GET and list on avatars, baas, chat and iceberg
  all return 403. A public-read bucket would answer 404 on a missing key.
- **U2 is not measured.** A presigned URL with `?apikey=` added for Kong may or may not still pass
  minio's signature check. `S3_PUBLIC_ENDPOINT` is empty live, so no browser-routable presigned URL
  is minted today.
- **The live edge config is a single-file bind mount.** It mounts the main groot checkout's
  `infrastructure/tls/nginx.conf`. The beta edge proxies `/storage/v1/` to prod `:3001`, so it
  inherits whatever headers `:3001` sends.

UNKNOWN = FAIL, so the minio route is treated as able to render active content on the app origin.

## Decision

1. **Edge sandbox (item 2).** Every `/storage/v1/` response from `:3001` carries
   `Content-Security-Policy: sandbox` and `X-Content-Type-Options: nosniff`. They are set at server
   scope through `map $uri` variables. An empty value emits no header, so no location-level
   `add_header` drops the server-level XFO, `frame-ancestors 'none'` and Permissions-Policy (SG-8).
   There is no media exception list and no edge `Content-Disposition` (SG-9).
2. **The false comment at the old `nginx.conf:132-135` is rewritten in the same commit (item 3,
   SG-15).**
3. **Router guard on (item 1).** The VM storage-router gets the value "1" from a durable file that
   every launch reads. Only that container is recreated, with `--no-deps --pull never --no-build`,
   after a render and a drift diff (SG-1–SG-7). This is defence in depth plus the presign guard.
   The edge change closes the path on its own.

Items 1 and 2 do not depend on each other, and neither needs the other's rollback.

## Alternatives considered

- **Load `docker-compose.prod.yml` on the VM.** It also switches strict identity mode and Kong admin,
  which is a far larger decision. It becomes right only if the VM is ruled a full production target.
- **`Content-Disposition: attachment` at the edge.** Sandbox already stops script. Disposition only
  breaks inline viewing, and the edge cannot scope it by type without parsing the upstream type.
- **Delete the Kong minio route.** Nothing in osionos uses it, so this is probably right. But it
  changes grobase's public gateway on the fly stack too, so it needs its own ruling.

## Consequences

- Landed on groot develop: 8a5e6b96 (red bats), b0942ccf (edge headers and comment), c3972a27
  (shellcheck). `scripts/tests/storage-edge-sandbox.bats` (5 tests) runs in
  `.github/workflows/storage-edge.yml` and fails on any skip.
- **Not live.** The live proxy reads the main checkout's file through a bind mount. Applying the
  change needs the operator to update that checkout, then prove the running config is the new one
  (`nginx -T` inside the container, SG-10), because a reload through a stale inode reloads the old
  text. If the proxy is recreated, render it first (SG-11).
- **Residual origins (SG-13).** The VM WAF `mini-baas-waf` (`10.0.2.15:8443`) and the fly stack front
  Kong `/storage/v1` without this header.
- `:8444` also fronts `/storage/v1` and stays unsandboxed. Changing it touches a cookie-bearing
  server, so it is left to the operator.
- A response that already carries nosniff from upstream can carry it twice. Browsers treat that
  the same as once.
- Open: U2, and item 1 under SG-1–SG-7 in a window with no uploads or co-edit sessions.
