// ===========================================================================
// osionos NATIVE edition — first-run database bootstrap.
//
// Runs ONCE against the freshly-initialised embedded Postgres (before the
// bridge/postgrest/gateway start): applies bootstrap.sql + the osionos
// migrations in the PoC-validated order, sets the authenticator password, and
// generates + persists the local secrets (JWT secret + signed role tokens).
// Idempotent: if the schema is already present it only ensures the secrets file.
//
// Pure Node (shells out to the bundled `psql`, uses node:crypto) — no deps.
//
// Standalone test:
//   PSQL_BIN=psql PGHOST=127.0.0.1 PGPORT=55432 PGSUPERUSER=postgres \
//   PGSUPERPASS=postgres OSIONOS_MIGRATIONS_DIR=./models \
//   OSIONOS_DATA_DIR=/tmp/osio-native node native/firstrun.mjs
// ===========================================================================
import { spawnSync } from "node:child_process";
import { randomBytes, createHmac } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// PoC-validated order: user.sql must precede auth-security (FK to public.users);
// rls-hardening last (it's self-guarding for absent gdpr fns).
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

// One psql invocation against the local superuser connection. Throws on failure.
function psql(cfg, args) {
  const base = ["-v", "ON_ERROR_STOP=1", "-h", cfg.host, "-p", String(cfg.port), "-U", cfg.superUser, "-d", cfg.db];
  const r = spawnSync(cfg.psqlBin, [...base, ...args], { env: { ...process.env, PGPASSWORD: cfg.superPass }, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`psql ${args.join(" ")} failed (${r.status}): ${(r.stderr || r.stdout || "").trim()}`);
  return (r.stdout || "").trim();
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

// Apply bootstrap + migrations (idempotent on the schema), set the authenticator
// password, and return the local secrets the supervisor wires into the services.
export function firstRun(cfg) {
  const secrets = ensureSecrets(cfg.dataDir);
  const alreadyBootstrapped = psql(cfg, ["-tAc", "SELECT to_regclass('public.osionos_pages') IS NOT NULL"]) === "t";
  if (!alreadyBootstrapped) {
    psql(cfg, ["-f", join(HERE, "bootstrap.sql")]);
    for (const m of MIGRATIONS) psql(cfg, ["-f", join(cfg.migrationsDir, m)]);
  }
  // Always (re)assert the authenticator login password to match the secrets file.
  psql(cfg, ["-c", `ALTER ROLE authenticator LOGIN PASSWORD '${secrets.authenticatorPassword}'`]);
  return { secrets, bootstrapped: !alreadyBootstrapped };
}

// CLI entrypoint (standalone testing).
if (import.meta.url === `file://${process.argv[1]}`) {
  const cfg = {
    psqlBin: process.env.PSQL_BIN || "psql",
    host: process.env.PGHOST || "127.0.0.1",
    port: Number(process.env.PGPORT || 5432),
    db: process.env.PGDATABASE || "postgres",
    superUser: process.env.PGSUPERUSER || "postgres",
    superPass: process.env.PGSUPERPASS || "postgres",
    migrationsDir: process.env.OSIONOS_MIGRATIONS_DIR || join(HERE, "..", "..", "..", "models"),
    dataDir: process.env.OSIONOS_DATA_DIR || "/tmp/osio-native",
  };
  const { bootstrapped } = firstRun(cfg);
  console.log(`[firstrun] ${bootstrapped ? "bootstrapped schema" : "schema already present"}; secrets ready in ${cfg.dataDir}/secrets.json`);
}
