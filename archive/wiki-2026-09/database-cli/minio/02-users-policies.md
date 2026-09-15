# 02 — Users, Policies, and Access Control

MinIO's access model is inspired by AWS IAM: **users** are authenticated identities, **policies** (JSON documents describing allowed actions and resources) are attached to users or groups. Unlike a relational database, permissions are defined at the **bucket and object-prefix level**, not the column or row level.

All examples use the `mcx` helper from [00-connect.md](00-connect.md).

---

## Users

### Add a user

```bash
mcx admin user add baas <username> <password>
```

Example:

```bash
mcx admin user add baas learn-reader LearnReader2024!
# Added user `learn-reader` successfully.
```

The password must be at least 8 characters.

### List users

```bash
mcx admin user ls baas
```

```
enabled    learn-reader
```

### Inspect a user

```bash
mcx admin user info baas learn-reader
```

```
AccessKey: learn-reader
Status: enabled
PolicyName: learn-media-ro
MemberOf: []
```

### Remove a user

```bash
mcx admin user rm baas learn-reader
# Removed user `learn-reader` successfully.
```

---

## Canned (built-in) policies

MinIO ships five canned policies. List them:

```bash
mcx admin policy ls baas
```

```
consoleAdmin
diagnostics
readonly
readwrite
writeonly
```

| Policy | What it grants |
|--------|----------------|
| `readonly` | `s3:Get*` + `s3:List*` on all buckets |
| `readwrite` | `s3:Get*` + `s3:List*` + `s3:Put*` + `s3:Delete*` on all buckets |
| `writeonly` | `s3:Put*` on all buckets |
| `consoleAdmin` | Full admin access including the web console |
| `diagnostics` | Read-only cluster diagnostics |

Canned policies are **global** — they grant access to every bucket. For production, prefer scoped custom policies.

### Attach a canned policy to a user

```bash
mcx admin policy attach baas readonly --user learn-reader
# Attached Policies: [readonly]
# To User: learn-reader
```

### Detach a policy

```bash
mcx admin policy detach baas readonly --user learn-reader
# Detached Policies: [readonly]
# From User: learn-reader
```

---

## Custom policies (scoped to a bucket or prefix)

A custom policy is a JSON document using the AWS IAM policy language. Write it inside a sidecar shell to avoid needing a volume mount:

```bash
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)

docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  --entrypoint /bin/sh \
  minio/mc -c '
cat > /tmp/learn-media-ro.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion"],
      "Resource": ["arn:aws:s3:::learn-media/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::learn-media"]
    }
  ]
}
EOF
mc admin policy create baas learn-media-ro /tmp/learn-media-ro.json
'
```

```
Created policy `learn-media-ro` successfully.
```

The `Resource` ARN `arn:aws:s3:::learn-media/*` scopes the policy to objects inside `learn-media` only — the user cannot list or read any other bucket.

### Attach and verify

```bash
mcx admin policy attach baas learn-media-ro --user learn-reader
# Attached Policies: [learn-media-ro]
# To User: learn-reader

mcx admin user info baas learn-reader
# PolicyName: learn-media-ro
```

### Remove a custom policy

```bash
mcx admin policy rm baas learn-media-ro
# Removed policy `learn-media-ro` successfully.
```

---

## Service accounts

A service account is a long-lived access key + secret key pair tied to a parent user. Its permissions are bounded by the parent user's policies (further restriction is possible but not expansion). Use service accounts for application credentials — rotate them without changing the user's policy.

```bash
mcx admin user svcacct add baas learn-reader
```

```
Access Key: X00GHAZM7KISSWSHSAOD
Secret Key: VqahSa1mDGi4f05kPa9B8CrcPJbVwuZIrFqBKAuT
Expiration: no-expiry
```

Store these as application secrets (e.g., in `.env.local` via vault42 — see the repo `CLAUDE.md`). The service account inherits the parent user's policy.

List service accounts for a user:

```bash
mcx admin user svcacct ls baas learn-reader
```

Remove a service account:

```bash
mcx admin user svcacct rm baas <access-key>
```

---

## Anonymous / public bucket access

Making a bucket publicly readable removes the need for credentials on `GET` requests — useful for static assets served directly over the S3 API.

```bash
mcx anonymous set download baas/learn-media
# Access permission for `baas/learn-media` is set to `download`
```

Check the setting:

```bash
mcx anonymous get baas/learn-media
# Access permission for `baas/learn-media` is `download`
```

Available modes: `none` (private, default), `download` (public GET/HEAD), `upload` (public PUT — dangerous), `public` (full anonymous access — never use in production).

Revert to private:

```bash
mcx anonymous set none baas/learn-media
```

---

## Scenario: a read-only user scoped to `learn-media`

This scenario sets up a user that can list and download objects from `learn-media` but cannot write, delete, or see any other bucket.

```bash
# 0. Credentials
AK=$(docker exec mini-baas-minio printenv MINIO_ROOT_USER)
SK=$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)
alias run_mc='docker run --rm --network mini-baas_mini-baas -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" minio/mc'

# 1. Create the bucket
run_mc mb baas/learn-media

# 2. Create the scoped policy
docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  --entrypoint /bin/sh \
  minio/mc -c '
cat > /tmp/policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion"],
      "Resource": ["arn:aws:s3:::learn-media/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::learn-media"]
    }
  ]
}
EOF
mc admin policy create baas learn-media-ro /tmp/policy.json
'

# 3. Create the user
run_mc admin user add baas learn-reader LearnReader2024!

# 4. Attach policy
run_mc admin policy attach baas learn-media-ro --user learn-reader

# 5. Verify
run_mc admin user info baas learn-reader

# 6. Cleanup (reverse order)
run_mc admin user rm baas learn-reader
run_mc admin policy rm baas learn-media-ro
run_mc rb --force baas/learn-media
```

---

## Gotchas / Docker notes

- **Policy JSON must be syntactically valid AWS IAM format.** MinIO validates it on create but errors are not always descriptive.
- **Users with no attached policy cannot access anything** — not even list buckets. There is no default-allow.
- **Service account permissions cannot exceed the parent user.** Attaching a broader policy to the service account directly is not supported.
- **Policy names are global per alias.** `learn-media-ro` on `baas` is visible to all connections to that server.
- **`mc admin policy attach` replaces, it does not accumulate.** To grant multiple policies attach them in a single call: `--policy p1,p2`.
- **Anonymous `upload` mode is a severe security risk** — it lets anyone PUT arbitrary objects into the bucket without authentication.

---

[README.md](README.md) | [00-connect.md](00-connect.md) | [01-buckets-objects.md](01-buckets-objects.md) | [03-security.md](03-security.md)
