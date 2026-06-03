# 08 — Edge Functions (MVP)

`functions-runtime` is a Deno container that lets tenants upload TS/JS
source and invoke it as a function-as-a-service. **This is an MVP** — the
isolation model is good enough for trusted tenants, not for hostile multi-
tenancy. Read the limitations below before exposing it publicly.

Lives in `apps/baas/mini-baas-infra/docker/services/functions-runtime/`.

## Bring it up

```sh
docker compose --profile functions up -d functions-runtime
```

## REST API

```http
POST   /v1/functions                       # upload {name, code}
GET    /v1/functions                       # list per tenant
GET    /v1/functions/:name                 # fetch source
DELETE /v1/functions/:name                 # remove
POST   /v1/functions/:name/invoke          # execute and return body
```

Tenant identity comes from `X-Baas-Tenant-Id` (post-M11 signed envelope)
with legacy fallbacks. Storage lives on the `functions-data` volume keyed
by `<tenant_id>/<name>.ts`.

### Upload

```sh
curl -X POST http://localhost:3060/v1/functions \
  -H "X-Baas-Tenant-Id: t-acme" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello",
    "code": "export default async (i) => ({ status: 200, body: { hi: i.body?.name ?? \"world\" } });"
  }'
```

### Invoke

```sh
curl -X POST http://localhost:3060/v1/functions/hello/invoke \
  -H "X-Baas-Tenant-Id: t-acme" \
  -H "Content-Type: application/json" \
  -d '{ "name": "claude" }'
# -> {"hi":"claude"}
```

## Function contract

```ts
export default async function (input: {
  tenant_id: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}): Promise<{
  status?: number;
  body?: unknown;
  contentType?: string;
}>
```

If your function throws, the server returns `500 { error: "function_error" }`
with the stack in the response body. Functions exceeding `FUNCTIONS_INVOKE_TIMEOUT_MS`
(default 5000ms) are terminated and return a timeout error.

## Isolation model

Each invocation spawns a fresh Deno Worker with this permission set:

```
read   = [<the specific .ts file>]
write  = none
env    = none
run    = none
ffi    = none
sys    = none
net    = inherit  (from the container)
```

The Worker terminates after sending its result. There is no shared state
between invocations of the same function. This means:

- **Cold start on every invocation** — ~20-40ms per call. No warm pool yet.
- Functions cannot read each other's source code.
- Functions cannot read environment variables (no secret leakage to user code).
- Functions can make outbound HTTP calls via `fetch` — there is no
  domain allow-list yet (planned).

## Limitations (be honest about these)

1. **No CPU/RAM hard caps.** Deno Workers run in the same V8 isolate as
   the server. A pathological function can burn CPU until the timeout
   fires but cannot be capped to a fraction of CPU. For hard caps, run
   the runtime container with `cpus: 0.5` / `mem_limit: 256m` so
   noisy-neighbour blast radius is bounded.
2. **No streaming responses.** Workers send a single message back.
   Server-Sent Events / WebSockets are out of scope.
3. **No durable invocations.** If the container crashes mid-execution,
   the call is lost. There's no retry/queue layer between the HTTP
   request and the worker.
4. **No package management.** Functions can `import` from
   `https://deno.land/...` URLs (HTTPS imports are allowed via `--allow-net`),
   but there's no `package.json`-like manifest. Pin your imports.
5. **Disk-backed storage.** Code is stored on a Docker volume, not in
   the control-plane DB. Use the volume backup strategy of your choice.
6. **No signed-URL or auth on the function endpoint itself.** The
   gateway is expected to inject the tenant identity header — exposing
   this service directly to the internet would let anyone read/write
   functions with a chosen `X-Baas-Tenant-Id` header.

## When to use something else

- High-trust customer code → run a separate runtime per tenant (one
  container per tenant; container-level cgroups).
- Long-running jobs → use the background plane (NestJS workers) instead.
- Code with native deps → not supported; Deno only.

## Production hardening checklist

- [ ] Front with the gateway and require a valid signed identity envelope.
- [ ] Add a domain allow-list for outbound `fetch` (custom Deno permission).
- [ ] Run one container per tenant for hard isolation.
- [ ] Track invocation metrics in `audit_log` for billing.
- [ ] Schedule garbage collection of unused function source.
