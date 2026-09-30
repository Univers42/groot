import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { TOKEN_FILE } from "./env";
import { loginOrRegister } from "./session";

// One gateway login per run; every context then mints its own handoff from this token.
export default async function globalSetup(): Promise<void> {
  mkdirSync(dirname(TOKEN_FILE), { recursive: true });
  writeFileSync(TOKEN_FILE, await loginOrRegister(), { mode: 0o600 });
}
