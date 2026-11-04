"use strict";
// The backend the app starts on launch: the docker compose suite (the LOCAL edition, or the dev
// checkout), or in the NATIVE edition the bundled runtime supervised as child processes.
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const { existsSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");

function trackBinocleHome() {
  return process.env.TRACK_BINOCLE_HOME
    || path.join(os.homedir(), "Documents", "ft_transcendence");
}

// Best-effort: bring the local suite up so opening the app starts the backend.
function bootSuite() {
  // LOCAL edition: the installer points OSIONOS_LOCAL_COMPOSE at the bundled
  // docker-compose.local.yml and we bring up only the lean `local` profile (HTTP).
  // Otherwise (dev repo) fall back to the full `dev` profile in the repo checkout.
  const localCompose = process.env.OSIONOS_LOCAL_COMPOSE;
  const cwd = localCompose ? path.dirname(localCompose) : trackBinocleHome();
  const args = localCompose
    ? ["compose", "-f", localCompose, "--profile", "local", "up", "-d"]
    : ["compose", "--profile", "dev", "up", "-d"];
  try {
    const child = spawn("docker", args, { cwd, detached: true, stdio: "ignore" });
    child.on("error", () => {}); // docker missing / no compose -> the app just shows offline
    child.unref();
  } catch { /* ignore */ }
}

// Boot the bundled backend (no Docker). Node children run under Electron's own
// binary via ELECTRON_RUN_AS_NODE, so we ship no separate `node`. The pg superuser
// password is generated once and persisted (postgres bakes it into PGDATA at initdb).
async function startNative({ nativeDir, userDataDir }) {
  const { startSuite, DEFAULT_PORTS } = await import(pathToFileURL(path.join(nativeDir, "native", "supervisor.mjs")).href);
  const dataDir = path.join(userDataDir, "native");
  mkdirSync(dataDir, { recursive: true });
  const pwPath = path.join(dataDir, "pgsuper.key");
  const superPass = existsSync(pwPath) ? readFileSync(pwPath, "utf8").trim()
    : (() => { const p = crypto.randomBytes(18).toString("hex"); writeFileSync(pwPath, p, { mode: 0o600 }); return p; })();
  const pgBin = path.join(nativeDir, "pgsql", "bin");
  const bin = {
    node: process.execPath, nodeEnv: { ELECTRON_RUN_AS_NODE: "1" },
    initdb: path.join(pgBin, "initdb"), postgres: path.join(pgBin, "postgres"),
    postgrest: path.join(nativeDir, "bin", "postgrest"),
    gotrue: path.join(nativeDir, "bin", "gotrue"), gotrueMigrations: path.join(nativeDir, "gotrue-migrations"),
    gatewayDir: path.join(nativeDir, "gateway"), gatewayScript: path.join(nativeDir, "gateway", "scripts", "auth-gateway.mjs"),
    bridgeScript: path.join(nativeDir, "bridge", "bridge-api.mjs"),
  };
  return startSuite({ bin, dataDir, ports: DEFAULT_PORTS, superPass, migrationsDir: path.join(nativeDir, "models"), appUrl: "app://osionos" });
}

module.exports = { bootSuite, startNative };
