// ===========================================================================
// osionos NATIVE edition — process supervisor (no Docker).
//
// Boots the lean backend as native child processes on loopback, in order, with
// a health gate between each, then hands the bridge URL to the Electron window:
//
//   embedded postgres ──▶ firstRun (bootstrap+migrations+secrets)
//     ──▶ PostgREST ──▶ restProxy (/rest/v1) ──▶ auth-gateway ──▶ bridge :4000
//
// Wiring validated by the Phase-2 PoC: stock postgres hosts the osionos schema;
// PostgREST + a service_role JWT serves it (200; 401 without); the bridge is a
// zero-dep Node process. `bin` paths are resolved by main.js from the bundled
// extraResources (build.sh --native). Pure Node — no deps.
// ===========================================================================
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { firstRun } from "./firstrun.mjs";
import { startRestProxy } from "./restProxy.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Poll an async predicate until it resolves truthy (or throw after the budget).
async function waitUntil(label, fn, { tries = 60, delayMs = 500 } = {}) {
  for (let i = 0; i < tries; i++) {
    try { if (await fn()) return; } catch { /* not ready yet */ }
    await sleep(delayMs);
  }
  throw new Error(`[supervisor] timed out waiting for ${label}`);
}

async function httpOk(url, init) {
  try { return (await fetch(url, init)).status < 500; } catch { return false; }
}

// ---- Postgres: initdb on first launch, then run on loopback --------------
function ensurePgData({ bin, dataDir, superPass }) {
  const pgdata = join(dataDir, "pgdata");
  if (existsSync(join(pgdata, "PG_VERSION"))) return pgdata;
  mkdirSync(dataDir, { recursive: true });
  const pwFile = join(dataDir, ".pgpw");
  writeFileSync(pwFile, superPass, { mode: 0o600 });
  const r = spawnSync(bin.initdb, ["-D", pgdata, "-U", "postgres", "--auth-host=scram-sha-256", "--auth-local=trust", `--pwfile=${pwFile}`], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`initdb failed: ${r.stderr || r.stdout}`);
  return pgdata;
}

function startPostgres({ bin, pgdata, port }, children) {
  // Loopback only; the unix socket lives in pgdata so nothing leaks to the host.
  const child = spawn(bin.postgres, ["-D", pgdata, "-p", String(port), "-c", "listen_addresses=127.0.0.1", "-k", pgdata], { stdio: "ignore" });
  children.push({ name: "postgres", child });
  return child;
}

// ---- the suite -----------------------------------------------------------
export async function startSuite(opts) {
  const { bin, dataDir, ports, superPass, migrationsDir, appUrl } = opts;
  const children = [];
  const stop = () => { for (const { child } of children.reverse()) { try { child.kill("SIGTERM"); } catch { /* */ } } };
  try {
    // 1. Postgres
    const pgdata = ensurePgData({ bin, dataDir, superPass });
    startPostgres({ bin, pgdata, port: ports.pg }, children);
    await waitUntil("postgres", () => spawnSync(bin.pg_isready, ["-h", "127.0.0.1", "-p", String(ports.pg), "-U", "postgres"]).status === 0);

    // 2. Schema + secrets (idempotent)
    const { secrets } = firstRun({ psqlBin: bin.psql, host: "127.0.0.1", port: ports.pg, db: "postgres", superUser: "postgres", superPass, migrationsDir, dataDir });

    // 3. PostgREST (connects as authenticator; JWT-gated) — proven path
    const rest = spawn(bin.postgrest, [], { stdio: "ignore", env: { ...process.env,
      PGRST_DB_URI: `postgres://authenticator:${secrets.authenticatorPassword}@127.0.0.1:${ports.pg}/postgres`,
      PGRST_DB_SCHEMAS: "public", PGRST_DB_ANON_ROLE: "anon",
      PGRST_JWT_SECRET: secrets.jwtSecret, PGRST_SERVER_PORT: String(ports.postgrest) } });
    children.push({ name: "postgrest", child: rest });
    await waitUntil("postgrest", () => httpOk(`http://127.0.0.1:${ports.postgrest}/osionos_workspaces`, { headers: { Authorization: "Bearer probe" } }));

    // 4. /rest/v1 rewrite shim in front of PostgREST (keeps the bridge unchanged)
    const proxy = await startRestProxy({ listenPort: ports.restProxy, postgrestUrl: `http://127.0.0.1:${ports.postgrest}` });
    children.push({ name: "rest-proxy", child: { kill: () => proxy.close() } });

    // 5. auth-gateway (Go) — credentials authority over public.users.
    //    TODO(impl): confirm the gateway's DB-DSN + JWT-secret env names from go/control-plane.
    const gw = spawn(bin.authGateway, [], { stdio: "ignore", env: { ...process.env,
      AUTH_GATEWAY_PORT: String(ports.gateway),
      DATABASE_URL: `postgres://postgres:${superPass}@127.0.0.1:${ports.pg}/postgres`,
      JWT_SECRET: secrets.jwtSecret } });
    children.push({ name: "auth-gateway", child: gw });
    await waitUntil("auth-gateway", () => httpOk(`http://127.0.0.1:${ports.gateway}/health`));

    // 6. bridge (zero-dep Node) — what the renderer talks to on :4000
    const bridge = spawn(bin.node, [bin.bridgeScript], { stdio: "ignore", env: { ...process.env,
      OSIONOS_BRIDGE_PORT: String(ports.bridge),
      OSIONOS_BAAS_URL: `http://127.0.0.1:${ports.restProxy}`,
      AUTH_GATEWAY_URL: `http://127.0.0.1:${ports.gateway}`,
      OSIONOS_BRIDGE_PERSISTENCE: "baas",
      SERVICE_ROLE_KEY: secrets.serviceRoleKey, PUBLIC_BAAS_ANON_KEY: secrets.anonKey,
      OSIONOS_APP_SESSION_SECRET: secrets.appSessionSecret, OSIONOS_BRIDGE_SHARED_SECRET: secrets.bridgeSharedSecret,
      OSIONOS_APP_URL: appUrl, OSIONOS_ALLOWED_ORIGIN: appUrl } });
    children.push({ name: "bridge", child: bridge });
    await waitUntil("bridge", () => httpOk(`http://127.0.0.1:${ports.bridge}/api/auth/bridge/health`));

    return { stop, bridgeUrl: `http://127.0.0.1:${ports.bridge}` };
  } catch (err) {
    stop();
    throw err;
  }
}

export const DEFAULT_PORTS = { pg: 54329, postgrest: 33001, restProxy: 4010, gateway: 8788, bridge: 4000 };
