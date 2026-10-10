import { defineConfig, devices } from "@playwright/test";

// The graph_render <graph-studio> runtime contract (tests/graph-studio-contract), against the pack
// app.Dockerfile pins, fetched by tests/graph-studio-contract/fetch-pack.sh into GS_PACK_DIR.
// No live stack: serve.mjs plays osionos-app's part. Same rules as the e2e suite: no retries.
const port = Number(process.env.GS_PORT ?? 4317);

export default defineConfig({
  testDir: "./graph-studio",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [["list"]],
  outputDir: "test-results/graph-studio",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node graph-studio/serve.mjs",
    url: `http://127.0.0.1:${port}/`,
    reuseExistingServer: false,
    timeout: 15_000,
    stdout: "pipe",
  },
});
