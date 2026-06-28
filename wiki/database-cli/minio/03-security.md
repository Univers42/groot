# 03 — Security: Hardening MinIO Object Storage

Object storage has a different attack surface from a relational database: there are no SQL injection vectors, but misconfigured bucket policies can expose entire datasets publicly. The main risks are credential exposure, overly permissive policies, and missing immutability controls.

All commands use the `mcx` helper from [00-connect.md](00-connect.md).

---

## Least-privilege policies

The single most important control. Every user and service account should be scoped to the minimum set of buckets, prefixes, and actions it actually needs.

### Do not use canned policies in production

`readonly` and `readwrite` grant access to **every bucket** on the server. A compromised service account with `readwrite` can exfiltrate or overwrite `chat/` and `iceberg/`. Always write custom policies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::my-bucket/uploads/*"]
    }
  ]
}
```

Scope by:
- **Bucket**: `arn:aws:s3:::my-bucket` (list, location)
- **Prefix**: `arn:aws:s3:::my-bucket/uploads/*` (objects under `uploads/`)
- **Action**: use the narrowest action set (`s3:GetObject` not `s3:*`)

### Verify effective permissions after any change

```bash
mcx admin user info baas <username>
```

Always confirm `PolicyName` reflects what you intended.

---

## Bucket policies vs. user policies

| | Bucket policy (`mc anonymous`) | User/IAM policy |
|---|---|---|
| Scope | A single bucket | Applies to the user wherever they connect |
| Enforcement | At the bucket level, affects all callers | Per-identity |
| Use case | Public static assets | Application credentials |
| Risk | Accidental public exposure | Over-privileged service accounts |

A bucket policy and a user policy are evaluated independently — access is granted if **either** allows it. If a bucket is set to `download` (anonymous), any user on the internet can GET objects regardless of user policies.

Check all bucket anonymous settings:

```bash
mcx anonymous list baas
```

Revoke public access on a bucket:

```bash
mcx anonymous set none baas/<bucket>
```

---

## Server-side encryption

MinIO supports SSE-S3 (AES-256 managed by a KMS) and SSE-C (customer-provided keys). In the `mini-baas` dev stack the KMS is not configured, so SSE-S3 via `mc encrypt set` is unavailable:

```bash
mcx encrypt set sse-s3 baas/learn-media
# mc: <ERROR> Unable to enable auto encryption. Server side encryption specified but KMS is not configured.
```

In a production deployment, configure the MinIO KMS plugin and then:

```bash
mcx encrypt set sse-s3 baas/<bucket>
# Encryption configuration successfully set on `baas/<bucket>`.

mcx encrypt info baas/<bucket>
# Auto encryption is enabled with sse-s3.
```

SSE-C (per-request key) can be used with any MinIO build but requires the client to supply the AES key on every request — not supported by the plain `mc` binary; use the S3 SDK directly.

**Dev stack note:** data-at-rest is protected only by host-level filesystem access controls. For local dev this is acceptable; for production, configure the KMS.

---

## Object locking, retention, and legal hold (WORM)

Object locking makes objects **Write Once Read Many (WORM)** — they cannot be deleted or overwritten for a specified period (or ever, with legal hold). This is the storage equivalent of an append-only audit log.

### Object lock must be enabled at bucket creation time

```bash
mcx mb --with-lock baas/learn-worm
# Bucket created successfully `baas/learn-worm`.
```

You cannot add object locking to an existing bucket.

### Legal hold — indefinite protection

Legal hold suspends deletion until it is explicitly cleared — no time limit. Suitable for preserving evidence.

```bash
# Upload an object
echo "immutable content" | docker run --rm -i \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="http://$AK:$SK@mini-baas-minio:9000" \
  minio/mc pipe baas/learn-worm/locked.txt

# Set legal hold
mcx legalhold set baas/learn-worm/locked.txt
# Object legal hold successfully set for `locked.txt`.

# Check status
mcx legalhold info baas/learn-worm/locked.txt
# [    ON    ]  locked.txt
```

While legal hold is ON, any `mc rm` or overwrite returns an error. To remove:

```bash
mcx legalhold clear baas/learn-worm/locked.txt
# Object legal hold successfully cleared for `locked.txt`.
```

### Retention — time-bounded WORM

Set a retention mode and duration at the bucket level:

```bash
# COMPLIANCE mode: even the root user cannot delete before expiry
mcx retention set --default COMPLIANCE 30d baas/learn-worm

# GOVERNANCE mode: users with bypass permission can override
mcx retention set --default GOVERNANCE 7d baas/learn-worm
```

Or per-object:

```bash
mcx retention set COMPLIANCE "2027-01-01" baas/learn-worm/report.pdf
```

**COMPLIANCE mode is irreversible for the lock period.** Only use it when you are certain about the retention window.

---

## Versioning for recovery

Versioning (covered in [01-buckets-objects.md](01-buckets-objects.md)) is also a security control: it provides a recovery path when objects are accidentally overwritten or deleted.

```bash
mcx version enable baas/<bucket>
```

With versioning enabled:
- Overwriting an object creates a new version; the old content is preserved.
- `mc rm` creates a delete marker; data is recoverable by restoring the previous version.
- Permanent deletion requires `mc rm --version-id <id>`.

In combination with retention, versioning makes objects both recoverable and tamper-resistant.

---

## TLS for the API endpoint

The `mini-baas` dev stack does not terminate TLS at the MinIO API level (`http://mini-baas-minio:9000`). In production, either:

1. Put MinIO behind a TLS-terminating reverse proxy (Nginx, Caddy), or
2. Configure MinIO's built-in TLS by placing certificates at `/root/.minio/certs/` inside the container.

For the sidecar to trust a custom CA, mount the CA cert and set:

```bash
docker run --rm \
  --network mini-baas_mini-baas \
  -e MC_HOST_baas="https://$AK:$SK@mini-baas-minio:9000" \
  -v /path/to/ca.crt:/root/.mc/certs/CAs/ca.crt \
  minio/mc ls baas
```

Or disable TLS verification for local dev only (never in production):

```bash
mcx --insecure ls baas
```

---

## Cluster and audit info

```bash
# Server health and configuration
mcx admin info baas

# Prometheus-compatible metrics (no auth required in dev)
curl -s http://127.0.0.1:9000/minio/health/live
# returns HTTP 200 when healthy

# List all admin events (if audit logging is configured)
mcx admin trace baas
```

---

## Practical hardening checklist

Work through this list before exposing MinIO outside the dev network:

- [ ] **No canned policies on service accounts.** Every service account has a custom, scoped policy.
- [ ] **No anonymous bucket access (`mc anonymous list baas` returns all `none`).**
- [ ] **Root credentials rotated** from the defaults generated by grobase self-start. Store in vault42.
- [ ] **Service accounts for applications, never the root key.** The root key is for admin operations only.
- [ ] **TLS enabled** on the API endpoint (not just the host-level proxy).
- [ ] **Versioning enabled** on all buckets containing important data.
- [ ] **Retention / legal hold** configured for compliance-relevant buckets.
- [ ] **Object lock (`--with-lock`) enabled** at creation time for any WORM bucket.
- [ ] **KMS configured** for SSE-S3 data-at-rest encryption in production.
- [ ] **`mc admin trace`** or an external audit log destination configured.
- [ ] **No `writeonly` or `public` anonymous modes** on any bucket.
- [ ] **Learn- buckets removed** after any training or testing session.

---

## Gotchas / Docker notes

- **`mc encrypt set sse-s3` requires a KMS.** The dev stack has no KMS configured. Document the error; do not retry in a loop.
- **COMPLIANCE retention cannot be shortened.** Once set, not even the root user can delete before expiry. Test with GOVERNANCE mode first.
- **`--with-lock` must be set at `mc mb` time.** There is no way to enable object locking on an existing bucket.
- **Legal hold blocks `rb --force`.** Clear legal holds before cleaning up a learn- bucket: `mcx legalhold clear --recursive --force baas/learn-worm`.
- **MinIO does not encrypt the API endpoint by default in the compose setup.** All traffic over `mini-baas_mini-baas` is plaintext inside the Docker network — acceptable for local dev, not for any internet-facing environment.

---

[README.md](README.md) | [00-connect.md](00-connect.md) | [01-buckets-objects.md](01-buckets-objects.md) | [02-users-policies.md](02-users-policies.md)
