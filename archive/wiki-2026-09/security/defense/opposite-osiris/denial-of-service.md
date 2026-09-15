# Denial-of-Service Resistance — opposite-osiris (marketing + auth website)

> The auth gateway enforces a hard 32 KiB request-body cap and a 256 MiB container memory ceiling, ensuring that a single oversized or malformed HTTP request cannot exhaust server memory or stall the gateway process.

## What it is (the concept)

**Denial-of-Service (DoS)** is any attack that prevents legitimate users from reaching a service by exhausting its compute, memory, or I/O budget. In HTTP services the classic vectors are **body-size amplification** (the client streams a huge payload that the server buffers in full before parsing) and **slow-resource attacks** (a deliberately large or falsely-declared `Content-Length` that ties up a worker until the connection times out). A well-designed server must **abort body reads early** and cap per-request memory so that a single connection cannot consume the whole process heap.

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

The opposite-osiris auth gateway is the single entry point for all login, signup, token-refresh, and session-management POST requests. Without a body cap, an attacker who can reach port 8787 (or the proxied HTTPS surface at `:4322`) could send a multi-megabyte body on every POST route — `readJson` would buffer the entire payload into a JavaScript string, ballooning V8 heap until the process OOM-crashed. A falsely-declared `Content-Length: 104857600` (100 MB) header paired with a slow-drip body achieves the same result by keeping the read loop open and blocking the event loop.

## How opposite-osiris implements it

**Body-size cap in the gateway parser**
[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) — `readJson` accumulates chunks from the Node.js request stream and throws `HTTP 413` the instant the running total exceeds 32,768 bytes:

```js
// auth-gateway.mjs lines 144-151
async function readJson(request) {
    let body = '';
    for await (const chunk of request) {
        body += chunk;
        if (body.length > 32_768) throw Object.assign(new Error('Request body too large.'), { status: 413 });
    }
    return body ? JSON.parse(body) : {};
}
```

`readJson` is the **only** body parser in the gateway; it is called on every authenticated POST route (lines 696, 969, 996, 1018 of the same file). There is no alternative path that accepts an unbounded body.

**Container memory ceiling**
[`docker-compose.yml`](../../../../docker-compose.yml) line 389 imposes `mem_limit: 256m` on the `auth-gateway` service. Even if an attacker somehow bypassed the per-request cap through concurrent connections, the Linux cgroup ceiling prevents a single container from consuming host RAM beyond 256 MiB.

**Large-request and header-flood resistance tests**
[`apps/opposite-osiris/scripts/security/08-rate-limit.mjs`](../../../../apps/opposite-osiris/scripts/security/08-rate-limit.mjs) lines 66-88 run three distinct DoS-surface probes against the live gateway:

- **Huge `Content-Length`** (lines 67-74): sends a request declaring a 100 MB body and asserts `result.timedOut === false` and the response status is a well-formed error (400/401/403/404/408/411/413/417/429) or a closed connection — no hanging.
- **200-header flood** (lines 76-88): sends a request with 200 custom `x-security-test-N` headers and asserts a timely response within 2 000 ms.
- **50 parallel REST requests** (lines 56-63): asserts all concurrent requests complete without process-level rejection.

## How we know it is applied

The security test script `08-rate-limit.mjs` is exercised as part of the stack's live verification suite. The check at lines 67-74 is unambiguous:

```js
// 08-rate-limit.mjs lines 67-74
{
    name: 'huge content-length rejected or closed',
    description: 'Checks a request claiming a 100 MB body is rejected or closed without hanging.',
    run: async () => {
        const result = await rawRequestWithHugeContentLength();
        assert.equal(result.timedOut, false, 'huge Content-Length request hung until timeout');
        assert.ok(result.closed || [400, 401, 403, 404, 408, 411, 413, 417, 429].includes(result.status), ...);
        return passed('Huge Content-Length request did not hang.');
    },
},
```

The `readJson` 413 path is the production code path — the same function is wired into every live POST handler (`/auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/token`). There is no separate "security mode": the cap is always active.

The `mem_limit: 256m` constraint in `docker-compose.yml` line 389 is enforced by Docker's cgroup integration at container startup; it requires no application-level opt-in and cannot be bypassed by the process running inside the container.

## Reference

The [OWASP Denial of Service Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) outlines the specific mitigations that apply here: input size limits, request timeouts, and resource constraints are listed as primary countermeasures against application-layer DoS. The implementation above directly maps to the "Limit Request Body Size" and "Container/Process Resource Limits" controls described in that guide.

## Residual risk / assumptions

- **Concurrent-connection exhaustion**: The 32 KiB per-body cap and 256 MiB cgroup limit reduce memory-per-connection pressure but do not throttle the number of simultaneous connections. A high-volume SYN or connection-slot flood against `:4322` or `:8787` is handled at the reverse-proxy layer (local-https-proxy → nginx), not in the auth gateway itself.
- **Trusted proxy hop assumption**: Rate-limit bucket keying relies on `AUTH_TRUSTED_PROXY_HOPS=2` (set in `docker-compose.yml` line 368) to derive the real client IP. If the deployment topology changes (extra load balancer, CDN), this value must be updated or spoofed `X-Forwarded-For` headers could let an attacker mint fresh rate-limit buckets, undermining the 50-parallel-request defence.
- **Redis availability**: The compose configuration (`REDIS_URL`) wires rate-limit state into `mini-baas-redis`. The comment at line 370 of `docker-compose.yml` acknowledges a **bounded in-memory fallback** if Redis is unreachable — meaning rate-limit state is not shared across gateway replicas in a multi-instance deployment.
- **No HTTPS-layer limits**: TLS termination happens in the local-https-proxy container; there is no `client_max_body_size` directive visible in this repo's nginx configuration for the opposite-osiris service, so the first defence against raw TCP/TLS-level floods remains outside the gateway's own controls.
