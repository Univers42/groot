import { defineConfig, devices } from "@playwright/test";
import { OSIONOS_URL } from "./lib/env";

// The Phase 4 captures (groot docs/redesign/PLAN.md §6.1): osionos as the Arlet demo users,
// shot at 2x. Run through scripts/media/capture.sh, which supplies the logins by name.
export default defineConfig({
  testDir: "./media",
  testMatch: /\.spec\.ts$/,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 300_000,
  expect: { timeout: 20_000 },
  reporter: [["list"]],
  outputDir: "test-results/media-artifacts",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: OSIONOS_URL,
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
    ignoreHTTPSErrors: false,
    trace: "retain-on-failure",
  },
});
