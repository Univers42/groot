# Request Body Size Limiting — grobase (the BaaS backend)

> grobase enforces tiered request body size caps at three independent layers — WAF, Kong gateway, and per-route plugin — so that no single oversized payload can exhaust memory in any service regardless of where an attacker targets the stack.

## What it is (the concept)

**Denial of Service (DoS)** defenses based on **request body size limiting** constrain the maximum amount of data a server will buffer from a single inbound HTTP request. Without such caps, a client can send a multi-gigabyte body and force the server to allocate memory proportionally, starving legitimate traffic. **Defense in depth** here means the cap is enforced redundantly: even if one layer is misconfigured or bypassed, the next layer still rejects the oversized payload before it reaches application code.

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

In the grobase context the risk is real: the BaaS exposes write-heavy endpoints (schema mutations, function source upload, SQL migration, binary storage) that each have legitimate large-body use cases but at very different scales. Without per-endpoint caps, an attacker authenticated with a free-tier API key could POST a 500 MB body to `/functions/v1` and exhaust the NestJS heap, cascading into dropped queries across all tenants.

## How grobase implements it

The protection is layered across three boundary points, each enforced by a different component:

**Layer 1 — WAF (outermost, all traffic)**

`apps/grobase/infra/docker/services/waf/conf/nginx.conf`, line 57:

```nginx
client_max_body_size 10m;
```

This is the public-facing nginx reverse proxy that sits in front of Kong. It terminates TLS and drops any request body exceeding 10 MB with a `413 Request Entity Too Large` before the payload reaches the gateway.

**Layer 2 — Kong nginx (gateway-wide)**

`apps/grobase/orchestrators/compose/base/gateway.yml`, lines 55–56:

```yaml
KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE: "1m"
KONG_NGINX_HTTP_CLIENT_BODY_TIMEOUT: "1s"
```

These environment variables tune Kong's embedded nginx. The `1m` hard cap applies to every route that does not carry a `request-size-limiting` plugin override; the `1s` body timeout closes slow-body connections that dribble data to hold a worker. Together they set a conservative baseline for the entire API surface.

**Layer 3 — Per-route `request-size-limiting` plugins (finest-grained)**

`apps/grobase/infra/docker/services/kong/conf/kong.yml` carries explicit per-service caps that override the gateway baseline where a route legitimately needs a different limit:

| Route / service | Cap | Reference lines |
|---|---|---|
| `admin-provision` (provisioning + key management) | **64 KB** | 500–503 |
| `admin-migrate` (schema migration endpoint) | **256 KB** | 700–701 |
| `functions-service` (function source upload) | **512 KB** | 1080–1083 |
| `query-router` (data-plane queries + transactions) | **1 MB** | 789–792 |

The admin endpoints carry the strictest caps because their attack surface (credential provisioning, credential rotation) is the most sensitive. The data-plane query endpoint is the most permissive at 1 MB — still well below the gateway's nginx cap — because it must accommodate batch inserts.

## How we know it is applied

The `kong.yml` file is bind-mounted read-only into the running Kong container:

```yaml
# gateway.yml line 63–64
volumes:
  - ./infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro
```

Kong reads this template at startup; the `request-size-limiting` plugin stanzas are inline in the same file as the route definitions, so there is no separate activation step. The Kong nginx environment variables (`KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE`, `KONG_NGINX_HTTP_CLIENT_BODY_TIMEOUT`) are set on the container itself in `gateway.yml` and take effect via Kong's nginx configuration injection mechanism at container start.

The WAF config at `infra/docker/services/waf/conf/nginx.conf` is baked into the WAF image build context; it is not a runtime toggle.

## Reference

The [OWASP Denial of Service Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) identifies resource exhaustion through oversized request payloads as a primary DoS vector and recommends enforcing size limits as close to the network edge as possible. Grobase applies exactly this principle by staging the cap at the WAF (edge), the gateway (cluster boundary), and the individual route (application boundary), so the defense degrades gracefully rather than failing as a single point.

## Residual risk / assumptions

- **Storage uploads bypass the 10 MB WAF cap by design**: the `storage-router` endpoint is explicitly intended for binary objects and carries a higher per-route cap (10 MB, matching the WAF). If object storage grows to accept very large files in future, the WAF cap must be raised to match.
- **Kong nginx body timeout of 1 s is aggressive**: slow-POST clients on high-latency links (mobile, satellite) may see legitimate requests rejected. The assumption is that all legitimate clients complete the body within 1 s; if vendor apps like Hypertube's bulk catalog ingest use the public Kong port, this could be a friction point.
- **The caps are per-connection, not per-tenant or per-key**: a tenant holding many concurrent connections can still send `N × 1 MB` in parallel. Rate-limiting plugins on the same routes provide the concurrent-connection dimension (see the `rate-limiting` stanzas adjacent to each `request-size-limiting` block in `kong.yml`).
- **The WAF `client_max_body_size 10m` applies only to the `location /` block** confirmed at line 57 of `nginx.conf`; any additional location blocks added in future must carry their own cap or they will inherit nginx's default (1 MB), which may be too restrictive or too permissive for the new route.
