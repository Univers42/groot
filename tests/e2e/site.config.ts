import { defineConfig, devices } from "@playwright/test";
import { PRISMATICA_URL } from "./lib/env";

// The site-only specs (st*): the built static site, no backend and no login, so they run in a
// PR's CI against the site's own image as well as locally (groot docs/redesign/PLAN.md §8.1).
export default defineConfig({
  testDir: "./specs",
  testMatch: /st\d+-.*\.spec\.ts$/,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  outputDir: "test-results/site-artifacts",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: PRISMATICA_URL,
    viewport: { width: 1440, height: 900 },
    trace: "retain-on-failure",
  },
});
