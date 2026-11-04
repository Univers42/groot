import { defineConfig, devices } from "@playwright/test";

// Every front door, in Chromium and Firefox, in parallel: reachable, trusted HTTPS, nothing in
// plain text, and what can be clicked works. `run.sh -c reach.config.ts`. It needs the frontends
// only; E2E_REACH_BACKEND=1 adds the checks that need grobase behind them.
export default defineConfig({
  testDir: "./reach",
  globalSetup: "./reach/global-setup.ts",
  fullyParallel: true,
  workers: 6,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [["list"]],
  outputDir: "test-results/reach-artifacts",
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
  ],
  use: { viewport: { width: 1440, height: 900 }, trace: "retain-on-failure" },
});
