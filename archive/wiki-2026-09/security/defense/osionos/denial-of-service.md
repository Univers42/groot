# Denial of Service — osionos (the block editor)

> The API client enforces a hard ceiling of six concurrent outbound requests and collapses identical in-flight GET calls into a single shared network call, preventing any view from amplifying into a backend request storm.

## What it is (the concept)

**Denial of Service (DoS)** is any condition that exhausts a shared resource — bandwidth, connection slots, memory, CPU — to the point that legitimate users cannot be served. In client-side applications the relevant form is **self-inflicted DoS**: a frontend that fires an unbounded fan-out of parallel requests can overwhelm its own backend just as effectively as an external attacker would. The countermeasure is **concurrency limiting** (capping simultaneous in-flight calls) combined with **request coalescing** (routing structurally identical queries through one shared network call).

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

In osionos, the concrete threat is a workspace view — such as a database or second-brain graph — that discovers many pages simultaneously and issues one API call per page. Without a cap, a view rendering 50+ items fires 50+ parallel requests to the osionos-bridge and the grobase BaaS in one tick. The code comment naming the threat explicitly: the BaaS rate-limits the bridge to HTTP 429 and 502 under such load, effectively denying service for all tabs in the session and backpressuring the shared grobase connection pool.

## How osionos implements it

**`apps/osionos/app/src/shared/api/client.ts`** — the sole HTTP transport used by every `api.get/post/patch/put/delete` call in the application — implements two complementary controls:

**1. Concurrency slot queue** (lines 61–77):

```ts
const MAX_CONCURRENT_REQUESTS = 6;
let activeRequests = 0;
const slotWaiters: Array<() => void> = [];

function acquireSlot(): Promise<void> {
  if (activeRequests < MAX_CONCURRENT_REQUESTS) {
    activeRequests += 1;
    return Promise.resolve();
  }
  return new Promise<void>((resolve) => slotWaiters.push(resolve));
}
```

Every call to `executeRequest` awaits `acquireSlot()` before opening the `fetch`. When all six slots are occupied, further callers queue behind a FIFO waiter array; `releaseSlot()` hands a slot directly to the next waiter without decrementing the counter, so the cap is never briefly exceeded.

**2. In-flight GET coalescing** (lines 80, 111–118):

```ts
const inflightGets = new Map<string, Promise<unknown>>();

async function request<T>(method: string, path: string, ...): Promise<T> {
  if (method !== 'GET') return executeRequest<T>(method, path, body, jwt);
  const key = `GET ${path}`;
  const shared = inflightGets.get(key);
  if (shared) return shared as Promise<T>;
  const pending = executeRequest<T>(method, path, body, jwt)
    .finally(() => inflightGets.delete(key));
  inflightGets.set(key, pending);
  return pending;
}
```

If the same `GET /path` arrives while a prior call is still in flight, the second caller receives the identical `Promise` and never opens a second network connection. The entry is cleaned up via `.finally()` so the Map does not grow unboundedly.

All exported helpers (`api.get`, `api.post`, etc.) delegate through `request()`, making these controls unconditional for every network operation in the app.

## How we know it is applied

Every consumer of the bridge or BaaS data plane goes through the `api` export from `client.ts`:

- `src/store/pageStore.actions.ts` calls `api.get`/`api.post`/`api.patch`/`api.delete` for all page CRUD.
- `src/store/sync/pageOutbox.ts` processes the offline-first outbox by replaying through the same `api.*` surface (via `publishPage`, called from `src/store/sync/usePageSync.ts`).
- Widget-level modules (`channel-messages`, `database-view`, `profile-page`, etc.) import `api` from `@/shared/api/client`.

The `executeRequest` function is not exported, so bypassing slot acquisition requires actively importing an unexported symbol — not possible under the project's TypeScript resolution. The shape is enforced structurally, not by convention.

## Reference

The [OWASP Denial of Service Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) categorises client-side request fan-out as an application-layer resource-exhaustion vector and recommends concurrency throttling as a primary mitigation at the consumer. The osionos implementation directly instantiates the "limit concurrent requests" and "coalesce duplicate requests" patterns described there, applied at the only network-egress point in the application.

## Residual risk / assumptions

- **Scope is client-side only.** The cap governs requests originating from a single browser tab; it provides no protection against multiple browser tabs, multiple users, or an attacker who calls the bridge directly (without going through the osionos frontend).
- **Cap is a constant, not adaptive.** `MAX_CONCURRENT_REQUESTS = 6` was chosen empirically; it is not adjusted by network latency, server backpressure signals, or BaaS plan tier. A future increase of that constant (e.g. during a refactor) silently degrades the protection.
- **GET coalescing is path-keyed, not JWT-keyed.** Two calls to the same path with different auth tokens share a single `Promise`. In practice this cannot happen within one browser session (the token is stable for a session), but it would become an issue if multi-tenant tab sharing were ever introduced.
- **POST/PATCH/DELETE mutations are slot-throttled but not coalesced.** A rapid sequence of identical mutations (e.g. double-click save) will be queued but each will execute; idempotency of those endpoints is a bridge-side concern, not enforced here.
- **No server-side enforcement is provided by this control.** Rate-limiting at the bridge and BaaS layers (HTTP 429 + retry-after) remains the backstop for any bypass of this client-side cap.
