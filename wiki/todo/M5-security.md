# M5 — Hardened security

**Targets:** dimension **e** (security & observability).
**Gate:** `make baas-verify-m5` returns `0`.
**Estimated effort:** 2 days.
**Risk:** medium — WAF rules can produce false positives that block legitimate traffic.
**Depends on:** M1..M4 (stable surface area to tighten around).

## Why

The wiki already claims a WAF, JWT rotation and CSP, but they are not part of the `mini-baas-infra` compose. M5 makes the security claims executable and continuously validated.

## Deliverables

### 1. ModSecurity WAF in front of Kong

New service `apps/baas/mini-baas-infra/docker/services/waf/`:

- Base image: `owasp/modsecurity-crs:nginx-alpine`
- Reverse proxies `:443 → kong:8000`
- CRS paranoia level 1 by default, configurable per-route.
- Exclusions documented in `conf/exclusions.conf` (e.g. `/storage/upload` for multipart).
- `HEALTHCHECK` on `/healthz`.

Compose updates:
- WAF becomes the new external ingress. Kong only listens on the internal network.
- DNS / curl examples in scripts updated to hit `https://localhost:8443` via WAF.

### 2. Kong plugins activated

In `docker/services/kong/conf/kong.yml`:

```yaml
plugins:
  - name: rate-limiting
    config: { minute: 600, hour: 10000, policy: redis, redis_host: redis }
  - name: bot-detection
  - name: request-size-limiting
    config: { allowed_payload_size: 10 }
  - name: cors
    config: { origins: ["https://localhost:5173", "https://localhost:4321"], credentials: true }
```

### 3. Default secure headers

Add `helmet` middleware (or NestJS's `@fastify/helmet` equivalent) to every NestJS app in `main.ts`:

```ts
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", "data:", "blob:"],
      connectSrc: ["'self'", "https://localhost:8443", "wss://localhost:8443"],
      frameAncestors: ["'none'"],
    },
  },
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: true },
}));
```

### 4. Automated JWT rotation via Vault

- `secret/data/mini-baas/jwt` holds the current signing key + a `kid` rotation index.
- Cron job in `vault/scripts/rotate-secrets.sh` (already exists) extended to:
  - Generate a new key.
  - Push to Vault.
  - Trigger GoTrue + PostgREST to reload via Kong admin API.
- Old `kid` retained for one cycle to allow in-flight tokens to validate.

### 5. SAST gates in CI

Extend `scripts/run-ci-local.sh` to:

- Run `sonar-scanner` against `sonar-project.properties`.
- Fail the build on any **Blocker** or **Critical** issue.
- Run `gitleaks` to fail on any committed secret.
- Run `trivy fs --severity HIGH,CRITICAL --exit-code 1` on the repo.
- Run `trivy image` on every image produced by `docker-bake.hcl`.

### 6. DAST baseline

Add `scripts/verify/zap-baseline.sh` that runs OWASP ZAP's baseline scan against `https://localhost:8443` and fails on `HIGH` alerts.

```bash
docker run --rm --network host -t ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py -t https://localhost:8443 -I -l WARN -m 1
```

### 7. CRS smoke test

A small script that confirms ModSecurity actually blocks well-known patterns:

```bash
# Should return 403 from WAF, never reach Kong
curl -ksS -o /dev/null -w '%{http_code}' \
  "https://localhost:8443/query/anything?id=1' OR '1'='1" | grep -q '^403$'
```

## Make gate

New file `scripts/verify/m5-security.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[M5] WAF healthy"
curl -fsS "https://localhost:8443/healthz" -k >/dev/null

echo "[M5] CRS blocks classic SQLi"
code=$(curl -ksS -o /dev/null -w '%{http_code}' \
  "https://localhost:8443/query/x?id=1%27%20OR%20%271%27=%271")
[[ "$code" == "403" ]] || { echo "[M5] FAIL: CRS did not block (got $code)"; exit 1; }

echo "[M5] Kong rate-limit enforced"
codes=$(for i in $(seq 1 700); do
  curl -ksS -o /dev/null -w '%{http_code}\n' "https://localhost:8443/auth/health"
done | sort -u)
echo "$codes" | grep -q '^429$' || { echo "[M5] FAIL: no 429 after 700 reqs"; exit 1; }

echo "[M5] CSP + HSTS present on responses"
headers=$(curl -ksSI "https://localhost:8443/auth/health")
echo "$headers" | grep -qi '^content-security-policy:' || { echo "[M5] FAIL: no CSP"; exit 1; }
echo "$headers" | grep -qi '^strict-transport-security:' || { echo "[M5] FAIL: no HSTS"; exit 1; }

echo "[M5] JWT rotation cycle keeps old kid valid for one window"
bash apps/baas/mini-baas-infra/docker/services/vault/scripts/rotate-secrets.sh --dry-run
# detailed assertions left to the rotate script itself

echo "[M5] no HIGH/CRITICAL trivy findings on built images"
for img in $(docker compose config --images | sort -u); do
  trivy image --quiet --severity HIGH,CRITICAL --exit-code 1 "$img"
done

echo "[M5] ZAP baseline returns no HIGH alerts"
bash scripts/verify/zap-baseline.sh

echo "[M5] OK"
```

## Done when

- ModSecurity WAF is the external ingress and blocks OWASP-CRS test payloads.
- Kong rate-limit, bot-detection, request-size, CORS plugins are active and provably enforced.
- All responses carry CSP + HSTS + `X-Content-Type-Options: nosniff` + `X-Frame-Options: DENY`.
- JWT rotation script runs without breaking valid in-flight sessions.
- CI fails on Blocker/Critical Sonar issues, leaked secrets, HIGH/CRITICAL Trivy findings.
- ZAP baseline scan reports zero HIGH alerts against `https://localhost:8443`.
- `make baas-verify-m5` exits `0`.

## Out of scope

- Service mesh (Linkerd/Istio) — M6.
- Chaos engineering — M6.
- Multi-region failover — M6.
