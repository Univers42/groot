import { defineConfig, devices } from "@playwright/test";

// The live stack is the fixture: no webServer, no retries — a retry would hide the
// flake this suite exists to catch.
export default defineConfig({
  testDir: "./specs",
  // run.sh sets E2E_SKIP_MAIL_SPECS when the live stack is unsafe for real-mail tests.
  testIgnore: process.env.E2E_SKIP_MAIL_SPECS ? [/\/(pr|dm)\d[^/]*\.spec\.ts$/] : [],
  globalSetup: "./lib/global-setup.ts",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [["list"]],
  outputDir: "test-results/artifacts",
  use: {
    ...devices["Desktop Chrome"],
    viewport: { width: 1440, height: 900 },
    actionTimeout: 15_000,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
});
