# Web Application Firewall — grobase (the BaaS backend)

> All public traffic to grobase is inspected and filtered by ModSecurity v3 running the OWASP Core Rule Set v4 in blocking mode before it ever reaches the internal Kong gateway.

## What it is (the concept)

A **Web Application Firewall (WAF)** is a reverse-proxy layer that sits between the public internet and a web application, examining HTTP requests and responses against a library of attack signatures. Unlike a network firewall, which operates at Layer 3/4, a WAF operates at **Layer 7** (the application layer) and understands HTTP semantics — headers, body encoding, query parameters, and URI structure. The **OWASP Core Rule Set (CRS)** is the industry-standard portable rule set for ModSecurity, covering injection, cross-site scripting, path traversal, and the rest of the OWASP Top 10. An **anomaly-scoring** engine accumulates points across multiple matched rules; a request is blocked only when the cumulative score crosses a configured threshold, reducing false positives relative to single-match blocking.

## What it defends against

See [Injection Attacks (SQLi, XSS)](../../attack/web-application-firewall.md). In grobase's context the threat is acute: the BaaS gateway exposes PostgREST filter syntax (`?column=eq.value`), GoTrue auth endpoints (Bearer tokens), raw JSON payloads for the query router, and file upload routes for object storage — all of which are high-value targets for SQL injection, XSS payload delivery, and path traversal. Supabase OSS, the upstream grobase inherits from, ships no WAF at all; this layer is an additive defense hardening that upstream layer.

## How grobase implements it

**The WAF is the sole public TCP listener.** Kong's port `8000` is bound only to `127.0.0.1` on the host; all external traffic must enter through the WAF service.

[`orchestrators/compose/base/gateway.yml`](../../../../apps/grobase/orchestrators/compose/base/gateway.yml) declares the `waf` service, publishes `${WAF_HTTP_PORT:-8880}:80` and `${WAF_HTTPS_PORT:-8443}:443`, and enforces `depends_on: kong: condition: service_healthy`. The companion Kong entry carries an explicit comment confirming the intent:

```yaml
# Kong is now internal — WAF is the public entrypoint.
# Keep 8000 exposed on localhost for direct dev access.
- "127.0.0.1:${KONG_HTTP_PORT:-8000}:8000"
```

[`infra/docker/services/waf/Dockerfile`](../../../../apps/grobase/infra/docker/services/waf/Dockerfile) builds from `owasp/modsecurity-crs:4-nginx-202604040104`, strips unnecessary packages (curl, perl, image-filter modules), copies the three config files with `--chown=nginx:root --chmod=0444/0644`, and drops to `USER nginx` for the final image — attacking the container surface before any payload is parsed.

[`infra/docker/services/waf/conf/nginx.conf`](../../../../apps/grobase/infra/docker/services/waf/conf/nginx.conf) defines the sole `server {}` block. It sets the upstream to `$kong_upstream http://kong:8000`, enables TLS 1.2/1.3 with secrets mounted from Docker Secrets (`localhost_cert` / `localhost_key`), and carves out exactly one bypass:

```nginx
location = /waf-health {
    modsecurity off;
    return 200 '{"status":"ok","service":"waf"}';
}
```

Everything else (`location /`) proxies through ModSecurity to Kong, with WebSocket upgrade headers forwarded for Realtime.

[`infra/docker/services/waf/conf/modsecurity.conf`](../../../../apps/grobase/infra/docker/services/waf/conf/modsecurity.conf) runs the engine in blocking mode and sets the request body ceiling:

```
SecRuleEngine On
SecRequestBodyAccess On
SecRequestBodyLimit 10485760
SecRequestBodyLimitAction Reject
```

It also patches three categories of known false positives that arise from BaaS-shaped traffic without widening the attack surface:

- **PostgREST filter syntax** (`/rest/v1/`): ten CRS rule IDs in the `942xxx` range (SQLi against ARGS) are removed from ARGS inspection only — the URI path and headers remain fully inspected.
- **Bearer tokens on auth routes** (`/auth/v1/`): three rules are removed from the `authorization` header only, because base64-encoded JWT values score as SQL injection candidates.
- **File upload content-type** (`/storage/v1/`): rule `920420` (content-type allowlist) is removed, since `application/octet-stream` is legitimate here.

[`infra/docker/services/waf/conf/crs-setup.conf`](../../../../apps/grobase/infra/docker/services/waf/conf/crs-setup.conf) tunes the CRS at Paranoia Level 2 with the default production thresholds:

```
setvar:tx.blocking_paranoia_level=2     # id:900000
setvar:tx.inbound_anomaly_score_threshold=5   # id:900110
setvar:tx.outbound_anomaly_score_threshold=4
```

Sampling is set to `100` (every request is checked), argument limits are raised to accommodate large BaaS payloads (`tx.max_num_args=512`, `tx.arg_length=4000`, `tx.total_arg_length=128000`), and allowed HTTP methods and content types are explicitly enumerated.

## How we know it is applied

[`scripts/verify/m140-network-controls.sh`](../../../../apps/grobase/scripts/verify/m140-network-controls.sh) — **ARM A** — is the load-bearing gate. It proves three non-vacuous sub-conditions:

**Block arm**: URL-encoded SQLi, XSS, and path-traversal probes each sent to the public WAF port must return `HTTP 403`:

```bash
SQLI_Q="id=1%27%20OR%20%271%27%3D%271%20--%20UNION%20SELECT%20password%20FROM%20users"
XSS_Q="q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
TRAV_Q="file=../../../../etc/passwd"
assert_block "SQLi"      "${WAF_URL}/anything?${SQLI_Q}"
assert_block "XSS"       "${WAF_URL}/search?${XSS_Q}"
assert_block "traversal" "${WAF_URL}/static?${TRAV_Q}"
```

**Pass arm**: a benign real route (`/data/v1/health`) must not be 403 — proving the WAF does not block all traffic:

```bash
BR="$(code "${WAF_URL}/data/v1/health")"
[[ "${BR}" == "403" ]] && fail "benign real route blocked — WAF false-positive"
```

**Negative control** (load-bearing): the same SQLi payload sent directly to Kong (bypassing the WAF) must not be 403, which attributes the block to the CRS engine rather than to Kong itself:

```bash
KD="$(code "${KONG_DIRECT_URL}/anything?${SQLI_Q}")"
[[ "${KD}" == "403" ]] && fail "SQLi direct-to-Kong also 403 — cannot attribute the block to the WAF"
```

When the live `mini-baas-waf` container is running, the gate also reads `docker logs mini-baas-waf --since 30s` and checks for CRS rule IDs (e.g. `941100`, `949110`) in the ModSecurity JSON audit log, confirming the engine — not a synthetic deny — fired. If the WAF container is absent, the gate spins up an isolated throwaway CRS container of the exact same image (`owasp/modsecurity-crs:4-nginx-202604040104`) with `MODSEC_RULE_ENGINE=on BLOCKING_PARANOIA=2 ANOMALY_INBOUND=5` and proves the same block/pass/negative-control triad there before tearing it down.

## Reference

The OWASP community page [Web Application Firewall](https://owasp.org/www-community/Web_Application_Firewall) defines a WAF as a control that applies a set of rules to HTTP conversations and covers the classes of attack a WAF can and cannot address. Grobase's implementation follows its guidance on anomaly scoring and paranoia level graduation to achieve defense depth without prohibitive false-positive rates in a JSON-heavy API surface.

## Residual risk / assumptions

- **Rule exclusions narrow the protection surface.** The ten SQLi rules removed from PostgREST ARGS (`/rest/v1/`) are disabled for all ARGS on that path, not just the filter column. A malformed filter value that scores exclusively on those ten rule IDs will not be blocked. The URI path and headers remain fully covered, and PostgREST itself parameterizes queries, but this is a genuine reduction.
- **Kong port is reachable on `127.0.0.1:8000` for local dev.** An attacker with local network access (e.g. a compromised process on the same host) can bypass the WAF entirely by targeting this port. The gate's negative-control arm demonstrates this explicitly.
- **The WAF does not inspect encrypted responses** (`SecResponseBodyAccess Off` in `modsecurity.conf`). Data exfiltration via a crafted response body is not detected by this layer.
- **Paranoia Level 2 is not Paranoia Level 3/4.** Some evasion techniques that accumulate score below 5 inbound will pass. Raising the paranoia level requires tuning the existing exclusion set to avoid blocking legitimate BaaS traffic.
- **No geographic or IP-reputation blocking** is wired at this layer; rate limiting is handled separately (see [`rate-limiting-brute-force.md`](rate-limiting-brute-force.md)).
- **The WAF image is pinned** (`4-nginx-202604040104`) and must be rebased periodically to pick up CRS rule updates and base-image security patches.
