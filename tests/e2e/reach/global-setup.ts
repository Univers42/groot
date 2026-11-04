import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { FIREFOX_STORE } from "./store";

// A Firefox certificate store holding the local CA and nothing else, as `make certs-trust-user`
// leaves a real profile. Playwright's Firefox ignores the system stores, so each test copies this.
export default function globalSetup(): void {
  rmSync(FIREFOX_STORE, { recursive: true, force: true });
  mkdirSync(FIREFOX_STORE, { recursive: true });
  execFileSync("certutil", ["-N", "--empty-password", "-d", `sql:${FIREFOX_STORE}`]);
  execFileSync("certutil", ["-A", "-t", "C,,", "-n", "track-binocle-local-ca", "-i", "/certs/local-ca.pem", "-d", `sql:${FIREFOX_STORE}`]);
}
