# MinIO CLI Learning Notes — Docker-only

MinIO is the S3-compatible object store powering the grobase backend (`mini-baas` stack). Unlike relational databases, MinIO organises data as **buckets** (namespace containers) and **objects** (arbitrary byte blobs with a key) — there are no tables, no rows, no schema, and no SQL.

All interaction goes through an `minio/mc` sidecar container. The MinIO server (`mini-baas-minio`) has no `mc` binary inside it.

---

## How the sidecar pattern works

```
Your shell
    │
    ▼
docker run --rm minio/mc …          ← ephemeral sidecar on the mini-baas network
    │
    ▼  http://mini-baas-minio:9000  ← MinIO API (S3-compatible)
mini-baas-minio container
```

The sidecar connects over Docker network `mini-baas_mini-baas`. It never needs to hit the host-published `:9000` port — it talks container-to-container.

---

## Credentials: never hardcode, always fetch at runtime

Root credentials live inside the server container as environment variables. Fetch them into shell variables first, then pass them via the `MC_HOST_<alias>` env var so they never appear in a file or in history:

```bash
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
# Now use $AK / $SK only within the same shell session
```

The `MC_HOST_<alias>` convention: `http://<access-key>:<secret-key>@<host>:<port>`. No config file is written to disk.

---

## The `mcx` helper — one-shot commands without repetition

Add this function to your shell profile (`.bashrc` / `.zshrc`) to wrap the full pattern:

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

Usage:

```bash
mcx ls baas
mcx mb baas/learn-media
mcx admin info baas
```

For interactive sessions (exploring, piping, scripting), see [00-connect.md](00-connect.md).

---

## Concept map: object storage vs. relational storage

| Object storage | Relational DB |
|----------------|---------------|
| Bucket | Database / schema |
| Object key (`img/2026/photo.jpg`) | Row primary key |
| Object (bytes + metadata) | Row (typed columns) |
| `mc cp` / `mc pipe` | `INSERT` / `UPDATE` |
| `mc rm` | `DELETE` |
| `mc ls` / `mc find` | `SELECT` |
| Versioning | Row history / audit log |
| Bucket policy | Table-level GRANT |

There is no foreign key, no join, no transaction. Objects are identified solely by their key string.

---

## File index

| File | Topic |
|------|-------|
| [00-connect.md](00-connect.md) | Sidecar setup, credential fetch, `mcx`, admin info, console URL |
| [01-buckets-objects.md](01-buckets-objects.md) | CRUD for buckets and objects, versioning, recursive ops |
| [02-users-policies.md](02-users-policies.md) | Users, canned and custom policies, service accounts, anonymous access |
| [03-security.md](03-security.md) | Least-privilege, object locking, WORM, TLS, hardening checklist |

All commands verified against `mini-baas-minio` (MinIO 2025-09-07, single-drive dev mode).
