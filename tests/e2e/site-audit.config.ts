import { defineConfig, devices } from "@playwright/test";
import { PRISMATICA_URL } from "./lib/env";

// The site-audit project measures the public site and records evidence for a labelled run
// (scripts/site-audit.sh): screenshots, axe violations, console errors. It asserts only that
// each route answered and its evidence was written; the redesign's gates judge the numbers.
export default defineConfig({
  testDir: "./site-audit",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 240_000,
  reporter: [["list"]],
  outputDir: "test-results/site-audit-artifacts",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: PRISMATICA_URL,
  },
});
