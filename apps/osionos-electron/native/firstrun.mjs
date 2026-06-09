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
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Authoritative production order (apps/baas/scripts/apply-project-sql.sh):
// user -> gdpr -> auth-security -> osionos-bridge -> folder-surface -> rls-hardening.
// gdpr adds users.deletion_requested_at/deleted_at (a migrated dump needs them);
// rls-hardening last (it grants on the gdpr functions). Calendar/mail are skipped
// (separate apps). bootstrap.sql (roles) runs before all of these.
const MIGRATIONS = [
  "user.sql",
  "gdpr-migration.sql",
  "auth-security-migration.sql",
  "osionos-bridge-migration.sql",
  "osionos-folder-surface-migration.sql",
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

// Apply bootstrap + osionos migrations (idempotent) + (re)assert the authenticator
// password; return the local secrets. NOTE: gotrue's auth.users is created later
// (when gotrue starts), so the data import runs separately, after gotrue — see importDump.
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

// One-time data import, run AFTER gotrue (which owns auth.users). If native-migrate.sh
// placed a dump at <dataDir>/import.sql, load it with FK triggers relaxed (order-
// independent), then mark it done so it only runs once. Superuser → bypasses RLS.
export async function importDump(cfg) {
  const file = join(cfg.dataDir, "import.sql");
  if (!existsSync(file)) return false;
  const client = await connectWithRetry(cfg);
  try {
    // Strip psql-only meta-commands (pg_dump 16.4 emits \restrict/\unrestrict) — the
    // pure-JS pg client speaks SQL, not psql backslash commands.
    const sql = readFileSync(file, "utf8").split("\n").filter((l) => !/^\\/.test(l)).join("\n");
    await client.query("SET session_replication_role = replica");
    try {
      await client.query(sql);
      // Some source rows carry an empty aud/role (older gotrue); this edition's gotrue
      // looks users up by aud='authenticated', so normalize imported accounts to match.
      await client.query("UPDATE auth.users SET aud = 'authenticated' WHERE aud IS NULL OR aud = ''");
      await client.query("UPDATE auth.users SET role = 'authenticated' WHERE role IS NULL OR role = ''");
    } finally { await client.query("SET session_replication_role = DEFAULT"); }
    renameSync(file, join(cfg.dataDir, `import-${Date.now()}.done.sql`));
    return true;
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
