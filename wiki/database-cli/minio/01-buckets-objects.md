# 01 — Buckets and Objects: the MinIO CRUD

In object storage there are no tables or rows. Data is organised into **buckets** (flat namespaces) containing **objects** (a key + a blob of bytes + metadata). The key is just a string — slashes in it are a naming convention that looks like a path, not a real directory hierarchy.

All examples use the `mcx` helper from [00-connect.md](00-connect.md). If you haven't set that up, replace every `mcx` with:

```bash
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
docker run --rm --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc
```

---

## Buckets

### Create

```bash
mcx mb baas/learn-media
# Bucket created successfully `baas/learn-media`.
```

A bucket is not a table — it holds no schema. Any object type can coexist inside it.

### List

```bash
mcx ls baas
```

```
[2026-06-25 12:03:02 UTC]     0B chat/
[2026-06-23 02:51:44 UTC]     0B iceberg/
[2026-06-28 10:29:00 UTC]     0B learn-media/
```

### Delete (empty bucket)

```bash
mcx rb baas/learn-media
```

### Force-delete (with all objects inside)

```bash
mcx rb --force baas/learn-media
```

Always use `learn-` prefixed buckets for experimentation and remove them at the end. Never run `rb --force` against `chat/` or `iceberg/`.

---

## Objects

Objects are addressed by `<alias>/<bucket>/<key>`. The key can contain slashes for logical organisation (`img/2026/june/photo.jpg`), but MinIO stores everything flat — there are no real subdirectories.

### Upload — `mc cp` (from a file)

To upload a local file you must either (a) copy it into the sidecar with `docker cp` or (b) use a volume mount. The easiest path is a volume:

```bash
# Write a file to a named volume, then mount it into the sidecar
docker run --rm \
  -v learn-upload:/data \
  busybox sh -c 'echo "hello from groot" > /data/hello.txt'

AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  -v learn-upload:/data \
  minio/mc cp /data/hello.txt baas/learn-media/hello.txt

docker volume rm learn-upload
```

### Upload — `mc pipe` (from stdin, no volume needed)

`mc pipe` reads stdin and writes it as a single object. This is the lightest approach for small objects or generated content:

```bash
echo "hello from groot" | docker run --rm -i \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-media/hello.txt
```

```
 0 B / ? 17 bytes -> `baas/learn-media/hello.txt`
```

Note: `-i` is required on the `docker run` so stdin is forwarded from your shell.

### List objects in a bucket

```bash
mcx ls baas/learn-media
```

```
[2026-06-28 10:29:18 UTC]    17B STANDARD hello.txt
```

### Find objects by pattern

```bash
mcx find baas/learn-media --name "*.txt"
```

```
baas/learn-media/hello.txt
```

`mc find` supports `--name` (glob), `--larger`, `--smaller`, `--older-than`, and `--newer-than` — useful for lifecycle queries you'd do with a `WHERE` clause in SQL.

### Read — `mc cat`

```bash
mcx cat baas/learn-media/hello.txt
```

```
hello from groot
```

### Read — `mc stat` (metadata only)

```bash
mcx stat baas/learn-media/hello.txt
```

```
Name      : hello.txt
Date      : 2026-06-28 10:29:18 UTC
Size      : 17 B
ETag      : 71c72e328fdd7fb31ead519f2c8121a8-1
Type      : file
Checksum  : CRC32C:8FCfvw==-1
Metadata  :
  Content-Type: text/plain
```

The ETag acts as a content hash — useful for cache-invalidation, not a primary key in the relational sense.

### Download — `mc cp` to local path

```bash
# Download into a volume, then docker cp to the host
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  -v learn-download:/out \
  minio/mc cp baas/learn-media/hello.txt /out/hello.txt

docker run --rm -v learn-download:/out busybox cat /out/hello.txt
docker volume rm learn-download
```

### Update — re-put the same key

Object storage has no in-place mutation. "Updating" an object means uploading a new blob under the same key, replacing the previous one:

```bash
echo "updated content v2" | docker run --rm -i \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-media/hello.txt
```

With versioning enabled the old content is preserved as a previous version (see below).

### Delete — `mc rm`

```bash
mcx rm baas/learn-media/hello.txt
```

With versioning enabled this creates a **delete marker** rather than permanently removing the object:

```
Created delete marker `baas/learn-media/hello.txt` (versionId=b05a37b7-...).
```

---

## Recursive and bulk operations

### Recursive copy (mirror a prefix)

```bash
mcx cp --recursive baas/learn-media/img/ baas/learn-backup/img/
```

### Mirror (sync two locations)

```bash
mcx mirror baas/learn-media baas/learn-backup
```

`mc mirror` is directional and idempotent — it copies only what is missing or changed in the destination.

---

## Versioning

Object versioning is a bucket-level feature. Once enabled, every put (upload) creates a new version; every delete creates a delete marker rather than destroying data. Think of it as an immutable audit log for your objects.

### Enable versioning

```bash
mcx version enable baas/learn-media
# baas/learn-media versioning is enabled
```

Must be done before the first write if you want v1 to be preserved. After enabling, upload two versions:

```bash
echo "version one" | docker run --rm -i --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-media/doc.txt

echo "version two" | docker run --rm -i --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-media/doc.txt
```

### List all versions

```bash
mcx ls --versions baas/learn-media
```

```
[2026-06-28 10:29:44 UTC]    19B STANDARD acac5e69-0610-430f-800c-83043434001b v2 PUT hello.txt
[2026-06-28 10:29:18 UTC]    17B STANDARD null                                  v1 PUT hello.txt
```

Each version has a unique `versionId`. `null` for v1 means it predates versioning being enabled.

### Check versioning status

```bash
mcx version info baas/learn-media
# baas/learn-media versioning is enabled
```

### Delete all versions (cleanup)

```bash
mcx rm --recursive --force --versions baas/learn-media
```

Then remove the bucket:

```bash
mcx rb --force baas/learn-media
```

---

## Scenario: create `learn-media`, upload, list, read, delete

```bash
# 0. Fetch credentials into the session
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)

# Shorthand for one-shot commands
alias run_mc='docker run --rm --network mini-baas_mini-baas -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" minio/mc'

# 1. Create bucket
run_mc mb baas/learn-media

# 2. Upload an object via pipe
echo '{"title":"Track Binocle","year":2026}' | docker run --rm -i \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-media/meta/project.json

# 3. List
run_mc ls baas/learn-media

# 4. Read back
run_mc cat baas/learn-media/meta/project.json

# 5. Inspect metadata
run_mc stat baas/learn-media/meta/project.json

# 6. Delete the object
run_mc rm baas/learn-media/meta/project.json

# 7. Remove the bucket
run_mc rb --force baas/learn-media
```

---

## Gotchas / Docker notes

- **Keys are not paths.** `img/2026/photo.jpg` is a single string key — there is no `img/` directory object. `mc ls baas/learn-media/img/` works by prefix filtering, not directory traversal.
- **No partial update.** You cannot update one byte of an object without re-uploading the whole thing.
- **ETags change on every put.** Don't use them as stable identifiers across updates.
- **`mc rm` with versioning creates a delete marker.** The data is not gone. To permanently expunge: `mc rm --version-id <id>`.
- **`--recursive` on `mc rm` + versioning requires `--versions`.** Without `--versions`, delete markers are created but old version bytes remain.
- **Stdin pipe requires `-i` on `docker run`.** Forgetting it causes a zero-byte object upload.

---

[README.md](README.md) | [00-connect.md](00-connect.md) | [02-users-policies.md](02-users-policies.md) | [03-security.md](03-security.md)
