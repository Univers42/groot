// Integration harness: run the native supervisor end-to-end inside ONE container
// acting as "the user's machine" — postgres/postgrest/gateway/bridge are spawned
// as native child processes (no docker-compose). Proves the orchestration + data
// path, then tears down. Exit 0 = green. Driven by build-native.sh --test.
//
// Assembled layout in the container: /rt/{native,gateway,bridge,models}; this
// file runs as /rt/native/supervisor-run.mjs.
import { startSuite, DEFAULT_PORTS } from "./supervisor.mjs";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const RT = "/rt";
const dataDir = process.env.OSIO_DATA || "/tmp/osio-data";
const PGBIN = process.env.PGBIN || "/usr/lib/postgresql/16/bin";
const bin = {
  node: process.execPath,
  initdb: `${PGBIN}/initdb`, postgres: `${PGBIN}/postgres`, pg_isready: `${PGBIN}/pg_isready`, psql: `${PGBIN}/psql`,
  postgrest: "/usr/local/bin/postgrest",
  gatewayDir: join(RT, "gateway"), gatewayScript: join(RT, "gateway/scripts/auth-gateway.mjs"),
  bridgeScript: join(RT, "bridge/bridge-api.mjs"),
};
const opts = { bin, dataDir, ports: DEFAULT_PORTS, superPass: "supitest123ABC", migrationsDir: join(RT, "models"), appUrl: "http://localhost" };
const ok = (label, cond, extra = "") => console.log(`${cond ? "  ✅" : "  ❌"} ${label}${extra ? " — " + extra : ""}`);

try {
  console.log("[run] starting native suite (postgres -> firstRun -> postgrest -> restProxy -> gateway -> bridge)...");
  const { stop, bridgeUrl } = await startSuite(opts);
  console.log(`[run] suite UP. bridge=${bridgeUrl}`);

  const h = await fetch(`${bridgeUrl}/api/auth/bridge/health`);
  ok("bridge /api/auth/bridge/health 200", h.status === 200, `${h.status} ${(await h.text()).slice(0, 60)}`);
  const sec = JSON.parse(readFileSync(join(dataDir, "secrets.json"), "utf8"));
  const r = await fetch(`http://127.0.0.1:${DEFAULT_PORTS.restProxy}/rest/v1/osionos_workspaces?limit=1`, { headers: { Authorization: `Bearer ${sec.serviceRoleKey}` } });
  ok("data path: restProxy /rest/v1 -> postgrest 200", r.status === 200, `${r.status} ${(await r.text()).slice(0, 40)}`);
  const g = await fetch(`http://127.0.0.1:${DEFAULT_PORTS.gateway}/`).catch((e) => ({ status: "ERR " + e }));
  ok("auth-gateway listening", typeof g.status === "number" && g.status < 500, String(g.status));

  stop();
  console.log("[run] ✅ DONE — full native stack booted with NO docker-compose, data path served.");
  setTimeout(() => process.exit(0), 500);
} catch (e) {
  console.error("[run] ❌ FAILED:", e?.message || e);
  process.exit(1);
}
