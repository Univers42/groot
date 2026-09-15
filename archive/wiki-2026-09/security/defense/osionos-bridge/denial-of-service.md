# Denial of Service (Request-Body Size Limits) — osionos-bridge (website-to-editor trust boundary)

> Every inbound HTTP body is capped during streaming before any parsing occurs; an oversized payload aborts with HTTP 413 and is never buffered into process memory.

## What it is (the concept)

**Denial of Service (DoS)** via **resource exhaustion** is an attack category in which an adversary consumes a process's bounded resources — memory, CPU, or file descriptors — until the service becomes unavailable to legitimate users. In single-process runtimes such as Node.js, **unbounded body buffering** is a classic amplification vector: a single large POST can exhaust the heap before any application logic executes. Defending against it requires enforcing an explicit **body-size limit** at the I/O layer, before deserialization, so the cost of an oversized request is O(limit), not O(payload).

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

In the osionos-bridge context, the risk is concrete: the bridge is a single-process Node.js HTTP server that holds the BaaS service-role key and proxies PostgREST/Kong on behalf of the editor. An attacker who can reach port 4000 — directly or through a misconfigured reverse proxy — could stream arbitrarily large bodies to exhaust the Node heap, stall the event loop, and cut the website-to-editor trust boundary for all users. Because the bridge uses Node's built-in `http` module (no framework body parser), the limit must be implemented explicitly in application code.

## How osionos-bridge implements it

Two separate modules enforce limits with the same streaming pattern — accumulate chunks, abort as soon as the running total exceeds the cap, never parse the rejected body.

**`apps/osionos/app/scripts/bridge-api.mjs`** — the main bridge router:

Two constants declare the tiered caps (lines 83–84):

```js
const DEFAULT_JSON_BODY_LIMIT_BYTES = 16_384;        // 16 KB — auth/handoff/control routes
const PAGE_JSON_BODY_LIMIT_BYTES    = 6 * 1024 * 1024; // 6 MB  — page-content routes
```

The shared `readJson` helper (lines 1315–1322) enforces the limit mid-stream:

```js
async function readJson(request, maxBytes = DEFAULT_JSON_BODY_LIMIT_BYTES) {
    let body = '';
    for await (const chunk of request) {
        body += chunk;
        if (body.length > maxBytes) throw Object.assign(new Error('Request body too large.'), { status: 413 });
    }
    return body ? JSON.parse(body) : {};
}
```

Auth and handoff routes (lines 2477, 2489, 2518) call `readJson(request)` with the 16 KB default. Page-content write routes (lines 1684, 1704, 1748, 1782, 1811, 2056, 2296, 2309, 2347, 2368, 2413) call `readJson(request, PAGE_JSON_BODY_LIMIT_BYTES)` to permit rich block payloads up to 6 MB.

**`apps/osionos/app/scripts/bridge-rtc.mjs`** — the standalone LiveKit token module:

A separate constant (`RTC_BODY_LIMIT_BYTES = 16_384`, line 52) and a parallel `readJsonBody` function (lines 171–182) apply the same mid-stream abort to `POST /api/rtc/token`:

```js
for await (const chunk of request) {
    body += chunk;
    if (body.length > RTC_BODY_LIMIT_BYTES) throw httpError('Request body too large.', 413);
}
```

Because `bridge-rtc.mjs` is deliberately standalone (no imports from `bridge-api.mjs`), it reimplements the guard rather than sharing it, ensuring the limit is in force even if the two modules are composed differently.

## How we know it is applied

The enforcement is structural, not optional: `readJson`/`readJsonBody` are the **only** body-reading entry points in both modules. Every POST and PATCH route passes its body exclusively through one of these two functions — there is no alternative code path that reads `request` directly and bypasses the cap. The 413 throw propagates before `JSON.parse` is ever reached, so the limit is enforced unconditionally on every mutating request.

The `bridge-api` test suite (`npm run test:bridge`, wired in `docker-compose.dev.yml`) exercises the auth-handoff flow and would catch any regression that removed or bypassed `readJson`.

## Reference

The [OWASP Denial of Service Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) categorises input-size limits as a primary mitigation for resource-exhaustion attacks and recommends enforcing them as close to the network layer as possible. The osionos-bridge implementation aligns with this guidance by applying the cap inside the async generator loop — at the first I/O boundary — rather than after full body accumulation.

## Residual risk / assumptions

- **No rate limiting.** The body-size cap prevents single-request memory exhaustion but does not bound the number of concurrent requests. A high-volume connection flood (L7 request-rate DoS) is not addressed; that protection belongs at the reverse proxy (Caddy/Kong) in front of port 4000.
- **String accumulation, not byte counting.** `body += chunk` accumulates a JavaScript string; for multi-byte UTF-8 sequences the character count may slightly undercount raw bytes. In practice the discrepancy is negligible at these limits.
- **Trust boundary assumption.** The guard assumes port 4000 is not exposed to the public internet — the bridge is intended to be reachable only from the frontend container and (in local dev) `localhost`. If network segmentation is misconfigured and port 4000 is publicly reachable, the size limit alone is insufficient.
- **6 MB page limit scope.** The 6 MB cap is deliberately generous to support large block-rich pages. An authenticated session that repeatedly submits near-maximum page payloads could still impose meaningful processing load on PostgREST/Kong downstream; no per-session request budget is enforced at the bridge layer.
