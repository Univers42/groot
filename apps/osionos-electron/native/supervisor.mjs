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
import { firstRun, importDump } from "./firstrun.mjs";
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

    // 2. Schema + secrets (idempotent). firstRun connect-retries via the pure-JS
    //    `pg` client == the postgres readiness gate (zonky ships no pg_isready/psql).
    const { secrets } = await firstRun({ host: "127.0.0.1", port: ports.pg, db: "postgres", superUser: "postgres", superPass, migrationsDir, dataDir });

    // 2b. gotrue (static Go binary) — the password authority for real accounts.
    //     Runs its own migrations into the auth schema; shares the JWT secret with
    //     postgrest + the gateway so tokens validate everywhere. Autoconfirm = no SMTP.
    const gotrue = spawn(bin.gotrue, [], { stdio: "ignore", env: { ...process.env,
      GOTRUE_API_HOST: "127.0.0.1", GOTRUE_API_PORT: String(ports.gotrue),
      GOTRUE_DB_DRIVER: "postgres",
      GOTRUE_DB_DATABASE_URL: `postgres://postgres:${superPass}@127.0.0.1:${ports.pg}/postgres?search_path=auth`,
      GOTRUE_DB_MIGRATIONS_PATH: bin.gotrueMigrations,
      GOTRUE_JWT_SECRET: secrets.jwtSecret, GOTRUE_JWT_AUD: "authenticated",
      GOTRUE_JWT_DEFAULT_GROUP_NAME: "authenticated", GOTRUE_JWT_EXP: "3600",
      GOTRUE_SITE_URL: appUrl, API_EXTERNAL_URL: `http://127.0.0.1:${ports.restProxy}/auth/v1`,
      GOTRUE_MAILER_AUTOCONFIRM: "true", GOTRUE_EXTERNAL_EMAIL_ENABLED: "true",
      GOTRUE_DISABLE_SIGNUP: "false", GOTRUE_LOG_LEVEL: "warn" } });
    children.push({ name: "gotrue", child: gotrue });
    await waitUntil("gotrue", () => httpOk(`http://127.0.0.1:${ports.gotrue}/health`), { tries: 90 });

    // 2c. One-time account/data import (now that gotrue owns auth.users).
    if (await importDump({ host: "127.0.0.1", port: ports.pg, db: "postgres", superUser: "postgres", superPass, dataDir })) {
      console.log("[supervisor] imported account + data dump");
    }

    // 3. PostgREST (connects as authenticator; JWT-gated) — proven path
    const rest = spawn(bin.postgrest, [], { stdio: "ignore", env: { ...process.env,
      PGRST_DB_URI: `postgres://authenticator:${secrets.authenticatorPassword}@127.0.0.1:${ports.pg}/postgres`,
      PGRST_DB_SCHEMAS: "public", PGRST_DB_ANON_ROLE: "anon",
      PGRST_JWT_SECRET: secrets.jwtSecret, PGRST_SERVER_PORT: String(ports.postgrest) } });
    children.push({ name: "postgrest", child: rest });
    await waitUntil("postgrest", () => httpOk(`http://127.0.0.1:${ports.postgrest}/osionos_workspaces`, { headers: { Authorization: "Bearer probe" } }));

    // 4. Kong-style routing shim: /rest/v1->postgrest, /auth/v1->gotrue (the gateway
    //    + bridge speak to one base URL with Kong's path conventions).
    const proxy = await startRestProxy({ listenPort: ports.restProxy, routes: [
      { prefix: "/rest/v1", target: `http://127.0.0.1:${ports.postgrest}` },
      { prefix: "/auth/v1", target: `http://127.0.0.1:${ports.gotrue}` },
    ] });
    children.push({ name: "rest-proxy", child: { kill: () => proxy.close() } });

    // 5. auth-gateway — a Node script (extracted from the prismatica image:
    //    scripts/auth-gateway.mjs + scripts/auth/* + node_modules/@mini-baas/js, ~232K).
    //    No gotrue service (marker only), no Redis (store.mjs falls back to a bounded
    //    in-memory map when REDIS_URL is empty). Talks to the DB via the SDK -> restProxy.
    //    cwd = gateway dir so its bundled node_modules resolve.
    const gw = spawn(bin.node, [bin.gatewayScript], { cwd: bin.gatewayDir, stdio: "ignore", env: { ...process.env, ...(bin.nodeEnv || {}),
      AUTH_GATEWAY_PORT: String(ports.gateway),
      PUBLIC_BAAS_URL: `http://127.0.0.1:${ports.restProxy}`,
      PUBLIC_BAAS_ANON_KEY: secrets.anonKey, SERVICE_ROLE_KEY: secrets.serviceRoleKey,
      TURNSTILE_BYPASS_LOCAL: "true", AUTH_REQUIRE_EMAIL_VERIFICATION: "false",
      OSIONOS_BRIDGE_URL: `http://127.0.0.1:${ports.bridge}/api/auth/bridge/session`,
      OSIONOS_BRIDGE_SHARED_SECRET: secrets.bridgeSharedSecret,
      OSIONOS_APP_SESSION_SECRET: secrets.appSessionSecret,
      PUBLIC_OSIONOS_APP_URL: appUrl, REDIS_URL: "" } });
    children.push({ name: "auth-gateway", child: gw });
    await waitUntil("auth-gateway", () => httpOk(`http://127.0.0.1:${ports.gateway}/`));

    // 6. bridge (zero-dep Node) — what the renderer talks to on :4000
    const bridge = spawn(bin.node, [bin.bridgeScript], { stdio: "ignore", env: { ...process.env, ...(bin.nodeEnv || {}),
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

export const DEFAULT_PORTS = { pg: 54329, gotrue: 9998, postgrest: 33001, restProxy: 4010, gateway: 8788, bridge: 4000 };
