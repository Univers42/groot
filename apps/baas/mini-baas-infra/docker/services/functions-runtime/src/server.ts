// Edge Functions runtime HTTP server.
// REST surface:
//   POST   /v1/functions             — upload {name, code, runtime?}
//   GET    /v1/functions             — list functions for the tenant
//   GET    /v1/functions/:name       — fetch source
//   DELETE /v1/functions/:name       — remove
//   POST   /v1/functions/:name/invoke — execute and return body
//
// Tenant identity is taken from the `X-Baas-Tenant-Id` header (post-M11) with
// fallbacks for compat. Storage lives under FUNCTIONS_DATA_DIR/<tenant>/<name>.ts.

import { dirname, join } from "https://deno.land/std@0.224.0/path/mod.ts";
import { ensureDir } from "https://deno.land/std@0.224.0/fs/ensure_dir.ts";

const PORT = Number(Deno.env.get("FUNCTIONS_PORT") ?? "3060");
const HOST = Deno.env.get("FUNCTIONS_HOST") ?? "0.0.0.0";
const DATA_DIR = Deno.env.get("FUNCTIONS_DATA_DIR") ?? "/data";
const TIMEOUT_MS = Number(Deno.env.get("FUNCTIONS_INVOKE_TIMEOUT_MS") ?? "5000");

// A2 Functions DX — per-function secrets. When FUNCTION_SECRETS_URL is set, the
// runtime resolves the tenant+function's whitelisted secrets from the Go
// secret store at invoke time and injects them into the Deno worker's env
// (spawned with `--allow-env=<keys>` and the values set in the worker's
// Deno.env). Without the URL, no secrets are injected (env stays disabled).
const SECRETS_URL = Deno.env.get("FUNCTION_SECRETS_URL") ?? "";
const SECRETS_TOKEN = Deno.env.get("INTERNAL_SERVICE_TOKEN") ?? "";

await ensureDir(DATA_DIR);

const ROUTES: Array<[string, RegExp, Handler]> = [
  ["POST", /^\/v1\/functions$/, createFn],
  ["GET", /^\/v1\/functions$/, listFns],
  ["GET", /^\/v1\/functions\/([^/]+)$/, readFn],
  ["DELETE", /^\/v1\/functions\/([^/]+)$/, deleteFn],
  ["POST", /^\/v1\/functions\/([^/]+)\/invoke$/, invokeFn],
  ["GET", /^\/health\/live$/, () => json(200, { status: "ok" })],
  ["GET", /^\/health\/ready$/, () => json(200, { status: "ready" })],
];

type Handler = (req: Request, match: RegExpMatchArray) => Promise<Response> | Response;

Deno.serve({ port: PORT, hostname: HOST }, async (req) => {
  try {
    const url = new URL(req.url);
    for (const [method, pattern, handler] of ROUTES) {
      if (req.method !== method) continue;
      const m = pattern.exec(url.pathname);
      if (m) return await handler(req, m);
    }
    return json(404, { error: "not_found", path: url.pathname });
  } catch (err) {
    console.error("[functions] unhandled", err);
    return json(500, { error: "internal_error", message: String(err) });
  }
});

console.log(`[functions] listening on ${HOST}:${PORT}, data=${DATA_DIR}`);

function tenantOf(req: Request): string | null {
  return req.headers.get("x-baas-tenant-id")
      ?? req.headers.get("x-baas-user-id")
      ?? req.headers.get("x-tenant-id")
      ?? req.headers.get("x-user-id");
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function unauthorized(): Response {
  return json(401, { error: "unauthorized", message: "missing X-Baas-Tenant-Id" });
}

function badName(name: string): boolean {
  return !/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/.test(name);
}

function pathFor(tenant: string, name: string): string {
  return join(DATA_DIR, tenant, `${name}.ts`);
}

async function createFn(req: Request): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  let body: { name?: string; code?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad_request", message: "invalid JSON" });
  }
  if (!body.name || badName(body.name)) {
    return json(400, { error: "validation_error", message: "name must match [a-zA-Z][a-zA-Z0-9_-]{0,63}" });
  }
  if (!body.code || body.code.length > 256_000) {
    return json(400, { error: "validation_error", message: "code required (max 256KB)" });
  }
  const dest = pathFor(tenant, body.name);
  await ensureDir(dirname(dest));
  await Deno.writeTextFile(dest, body.code);
  return json(201, { name: body.name, bytes: body.code.length });
}

async function listFns(req: Request): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const dir = join(DATA_DIR, tenant);
  const out: Array<{ name: string; bytes: number; updated_at: string }> = [];
  try {
    for await (const entry of Deno.readDir(dir)) {
      if (!entry.isFile || !entry.name.endsWith(".ts")) continue;
      const stat = await Deno.stat(join(dir, entry.name));
      out.push({
        name: entry.name.replace(/\.ts$/, ""),
        bytes: stat.size,
        updated_at: (stat.mtime ?? new Date(0)).toISOString(),
      });
    }
  } catch (err) {
    if (!(err instanceof Deno.errors.NotFound)) throw err;
  }
  return json(200, out);
}

async function readFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });
  try {
    const code = await Deno.readTextFile(pathFor(tenant, name));
    return json(200, { name, code });
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }
}

async function deleteFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });
  try {
    await Deno.remove(pathFor(tenant, name));
    return json(200, { deleted: true });
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }
}

async function invokeFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });

  const codePath = pathFor(tenant, name);
  try {
    await Deno.stat(codePath);
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }

  let inputBody: unknown = null;
  const ctype = req.headers.get("content-type") ?? "";
  if (ctype.includes("application/json")) {
    try {
      inputBody = await req.json();
    } catch {
      inputBody = null;
    }
  } else {
    inputBody = await req.text();
  }

  const headers: Record<string, string> = {};
  req.headers.forEach((v, k) => { headers[k] = v; });

  const secrets = await resolveSecrets(tenant, name);

  const result = await invokeInWorker(codePath, {
    tenant_id: tenant,
    method: req.method,
    headers,
    body: inputBody,
  }, secrets);
  if (result.error) {
    return json(500, { error: "function_error", message: result.error });
  }
  return new Response(typeof result.body === "string" ? result.body : JSON.stringify(result.body), {
    status: result.status ?? 200,
    headers: { "content-type": result.contentType ?? "application/json" },
  });
}

// resolveSecrets fetches the tenant+function's decrypted secrets from the Go
// secret store. Failures are non-fatal — the function just runs without the
// secrets injected (logged). Returns {} when no store is configured.
async function resolveSecrets(tenant: string, name: string): Promise<Record<string, string>> {
  if (!SECRETS_URL) return {};
  try {
    const u = new URL(SECRETS_URL);
    u.searchParams.set("tenant", tenant);
    u.searchParams.set("function", name);
    const resp = await fetch(u.toString(), {
      headers: SECRETS_TOKEN ? { "X-Internal-Service-Token": SECRETS_TOKEN } : {},
    });
    if (!resp.ok) {
      console.error(`[functions] secret resolve failed: HTTP ${resp.status}`);
      return {};
    }
    const data = await resp.json();
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(data ?? {})) {
      if (typeof v === "string") out[k] = v;
    }
    return out;
  } catch (err) {
    console.error("[functions] secret resolve error", err);
    return {};
  }
}

interface InvokeInput {
  tenant_id: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

interface InvokeResult {
  status?: number;
  body?: unknown;
  contentType?: string;
  error?: string;
}

function invokeInWorker(
  codePath: string,
  input: InvokeInput,
  secrets: Record<string, string> = {},
): Promise<InvokeResult> {
  return new Promise((resolve) => {
    const secretKeys = Object.keys(secrets);
    // The worker imports the handler dynamically AFTER seeding Deno.env so the
    // handler reads its secrets via the normal Deno.env.get(...) API. env
    // permission is scoped to exactly the whitelisted keys (least privilege);
    // when there are no secrets, env stays disabled.
    const workerSource = `
      const __secrets = ${JSON.stringify(secrets)};
      for (const [k, v] of Object.entries(__secrets)) {
        try { Deno.env.set(k, v); } catch (_) { /* env not permitted */ }
      }
      const { default: handler } = await import("file://${codePath}");
      self.onmessage = async (ev) => {
        try {
          const out = await handler(ev.data);
          self.postMessage({ ok: true, out });
        } catch (e) {
          self.postMessage({ ok: false, error: (e && e.stack) || String(e) });
        } finally {
          self.close();
        }
      };
    `;
    const blob = new Blob([workerSource], { type: "application/typescript" });
    const url = URL.createObjectURL(blob);
    const worker = new Worker(url, {
      type: "module",
      deno: {
        permissions: {
          read: [codePath],
          net: "inherit",
          // Scope env to exactly the whitelisted secret keys, else disable.
          env: secretKeys.length > 0 ? secretKeys : false,
          run: false,
          write: false,
          ffi: false,
          sys: false,
        },
      },
    } as WorkerOptions);

    const timeout = setTimeout(() => {
      worker.terminate();
      URL.revokeObjectURL(url);
      resolve({ error: `timeout after ${TIMEOUT_MS}ms` });
    }, TIMEOUT_MS);

    worker.onmessage = (ev) => {
      clearTimeout(timeout);
      URL.revokeObjectURL(url);
      const msg = ev.data as { ok: boolean; out?: InvokeResult; error?: string };
      resolve(msg.ok ? (msg.out ?? {}) : { error: msg.error });
    };
    worker.onerror = (ev) => {
      clearTimeout(timeout);
      URL.revokeObjectURL(url);
      resolve({ error: ev.message });
    };
    worker.postMessage(input);
  });
}
