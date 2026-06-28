# 00 — Connecting to MinIO via the mc Sidecar

The MinIO server (`mini-baas-minio`) exposes an S3-compatible API but ships no client binary. Every `mc` command is run via an ephemeral `minio/mc` sidecar container on the same Docker network.

---

## Step 1 — Fetch credentials at runtime

Root credentials live in the server's environment. Never hardcode them in scripts, commit them, or echo them to a terminal you screen-share.

```bash
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
```

Verify you got them (masked):

```bash
echo "AK=${AK:0:3}*** SK=${SK:0:3}***"
# AK=min*** SK=e13***
```

---

## Step 2 — The `MC_HOST_<alias>` env var

Instead of running `mc alias set` (which writes credentials to a config file inside the container), pass the alias inline via an environment variable:

```
MC_HOST_baas="http://<access-key>:<secret-key>@mini-baas-minio:9000"
```

`baas` is the alias name — it's arbitrary and local to this shell session. The URL embeds the key pair so no config file is ever written to disk.

---

## Pattern (a) — One-shot command

```bash
docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc ls baas
```

Expected output:

```
[2026-06-25 12:03:02 UTC]     0B chat/
[2026-06-23 02:51:44 UTC]     0B iceberg/
```

Buckets are analogous to top-level namespaces — not tables. Each line is a bucket, not a row.

---

## Pattern (b) — Interactive shell

```bash
docker run --rm -it \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  --entrypoint /bin/sh \
  minio/mc
```

Inside the shell you can chain multiple `mc` commands without container start-up overhead:

```sh
mc ls baas
mc admin info baas
mc mb baas/learn-scratch
mc rb --force baas/learn-scratch
exit
```

---

## The `mcx` helper function — recommended for day-to-day use

Add to your shell profile (`~/.bashrc` or `~/.zshrc`):

```bash
mcx() {
  local AK SK
  AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
  SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
  docker run --rm \
    --network mini-baas_mini-baas \
    -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
    minio/mc "$@"
}
```

Then:

```bash
source ~/.bashrc   # or restart your shell
mcx ls baas
mcx admin info baas
```

`mcx` re-fetches credentials on every call, so it survives secret rotations without any reconfiguration.

---

## `mc alias set` — the alternative (config-file approach)

For the interactive-shell pattern you can also register the alias once inside the container session:

```sh
# inside the interactive shell
mc alias set baas http://mini-baas-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
```

This writes to `/root/.mc/config.json` inside the container, which disappears when the container exits. The `MC_HOST_<alias>` env-var approach is preferred because it leaves no artefact.

---

## Server info

```bash
mcx admin info baas
```

Expected output (abridged):

```
●  mini-baas-minio:9000
   Uptime: 14 hours
   Version: 2025-09-07T16:13:09Z
   Network: 1/1 OK
   Drives: 1/1 OK
   Pool: 1

8.8 MiB Used, 2 Buckets, 58 Objects
1 drive online, 0 drives offline, EC:0
```

---

## Host vs. in-network endpoints

| Access path | Endpoint | When to use |
|-------------|----------|-------------|
| Container-to-container (sidecar) | `http://mini-baas-minio:9000` | All `mc` sidecar commands |
| Host browser / `curl` from the host | `http://127.0.0.1:9000` | Ad-hoc S3 API calls from the host |
| MinIO web console | `http://localhost:9001` | Visual exploration — browser only |

The container hostname `mini-baas-minio` resolves only inside the Docker network `mini-baas_mini-baas`. From the host you must use `127.0.0.1`.

---

## Web console

Open `http://localhost:9001` in a browser. Use the same root credentials (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) to log in. The console lets you browse buckets and objects visually but is not scriptable — for automation always use `mc`.

---

## Scratch-bucket convention

When learning or testing, always prefix your buckets with `learn-`:

```bash
mcx mb baas/learn-scratch
# ... experiment ...
mcx rb --force baas/learn-scratch
```

This prevents accidental mutation of production buckets (`chat/`, `iceberg/`). See [01-buckets-objects.md](01-buckets-objects.md) for the full bucket and object lifecycle.

---

## Gotchas / Docker notes

- **`--rm` is essential.** Without it, stopped sidecar containers accumulate. Every `docker run` here uses `--rm`.
- **`-i` for pipes.** When piping content into `mc pipe`, add `-i` to the `docker run` flags so stdin is forwarded: `echo "data" | docker run --rm -i ...`.
- **Network must be `mini-baas_mini-baas`.** If you see "dial tcp: lookup mini-baas-minio: no such host", you forgot `--network`.
- **No `mc` inside the server.** `docker exec mini-baas-minio mc …` will fail — the server image ships only the MinIO binary, not the client.
- **Credentials are not rotated automatically.** Re-running `docker exec mini-baas-minio printenv …` always returns the current values.

---

[README.md](README.md) | [01-buckets-objects.md](01-buckets-objects.md) | [02-users-policies.md](02-users-policies.md) | [03-security.md](03-security.md)
