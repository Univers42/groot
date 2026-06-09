// ===========================================================================
// osionos NATIVE edition — first-run database bootstrap.
//
// Applies bootstrap.sql + the osionos migrations (PoC-validated order) to the
// freshly-initialised embedded Postgres, sets the authenticator password, and
// generates + persists the local secrets. Idempotent.
//
// Uses the pure-JS `pg` client (NOT psql/pg_isready) — the bundled
// embedded-postgres (zonky) ships only initdb/pg_ctl/postgres, no client tools.
// `pg` is bundled under native-runtime/node_modules. The connect-retry doubles
// as the postgres readiness gate.
// ===========================================================================
import pg from "pg";
import { randomBytes, createHmac } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// PoC-validated order: user.sql before auth-security (FK to public.users);
// rls-hardening last (self-guarding for absent gdpr fns).
const MIGRATIONS = [
  "osionos-bridge-migration.sql",
  "osionos-folder-surface-migration.sql",
  "user.sql",
  "auth-security-migration.sql",
  "rls-hardening-migration.sql",
];

function signJwt(payload, secret) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const data = `${enc({ alg: "HS256", typ: "JWT" })}.${enc({ ...payload, iat: Math.floor(Date.now() / 1000) })}`;
  return `${data}.${createHmac("sha256", secret).update(data).digest("base64url")}`;
}

// Load the persisted secrets, or generate + write them (mode 600) on first run.
function ensureSecrets(dataDir) {
  const file = join(dataDir, "secrets.json");
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8"));
  const jwtSecret = randomBytes(48).toString("hex");
  const secrets = {
    jwtSecret,
    authenticatorPassword: randomBytes(24).toString("hex"),
    appSessionSecret: randomBytes(32).toString("hex"),
    bridgeSharedSecret: randomBytes(32).toString("hex"),
    serviceRoleKey: signJwt({ role: "service_role" }, jwtSecret),
    anonKey: signJwt({ role: "anon" }, jwtSecret),
  };
  mkdirSync(dataDir, { recursive: true });
  writeFileSync(file, JSON.stringify(secrets, null, 2), { mode: 0o600 });
  return secrets;
}

// Connect as the superuser, retrying until postgres accepts connections (the
// readiness gate). Throws after the budget.
async function connectWithRetry(cfg, tries = 90, delayMs = 500) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    const client = new pg.Client({ host: cfg.host, port: cfg.port, user: cfg.superUser, password: cfg.superPass, database: cfg.db });
    try { await client.connect(); return client; }
    catch (e) { lastErr = e; try { await client.end(); } catch { /* */ } await sleep(delayMs); }
  }
  throw new Error(`postgres did not become ready: ${lastErr?.message || "unknown"}`);
}

// Apply bootstrap + migrations (idempotent) + (re)assert the authenticator
// password; return the local secrets the supervisor wires into the services.
export async function firstRun(cfg) {
  const secrets = ensureSecrets(cfg.dataDir);
  const client = await connectWithRetry(cfg);
  try {
    const { rows } = await client.query("SELECT to_regclass('public.osionos_pages') IS NOT NULL AS done");
    const bootstrapped = !rows[0].done;
    if (bootstrapped) {
      await client.query(readFileSync(join(HERE, "bootstrap.sql"), "utf8"));
      for (const m of MIGRATIONS) await client.query(readFileSync(join(cfg.migrationsDir, m), "utf8"));
    }
    await client.query(`ALTER ROLE authenticator LOGIN PASSWORD '${secrets.authenticatorPassword}'`);
    return { secrets, bootstrapped };
  } finally {
    await client.end();
  }
}

// CLI entrypoint (standalone testing).
if (import.meta.url === `file://${process.argv[1]}`) {
  const cfg = {
    host: process.env.PGHOST || "127.0.0.1",
    port: Number(process.env.PGPORT || 5432),
    db: process.env.PGDATABASE || "postgres",
    superUser: process.env.PGSUPERUSER || "postgres",
    superPass: process.env.PGSUPERPASS || "postgres",
    migrationsDir: process.env.OSIONOS_MIGRATIONS_DIR || join(HERE, "..", "..", "..", "models"),
    dataDir: process.env.OSIONOS_DATA_DIR || "/tmp/osio-native",
  };
  const { bootstrapped } = await firstRun(cfg);
  console.log(`[firstrun] ${bootstrapped ? "bootstrapped schema" : "schema already present"}; secrets in ${cfg.dataDir}/secrets.json`);
  process.exit(0);
}
