import { expect, test as base, type Page } from "@playwright/test";

type Guard = { watch(page: Page, label: string): void };

// Playwright's own injected scripts are refused by a sandboxed frame without allow-scripts,
// and Chromium logs that as the page's error (microsoft/playwright#33343). Measured
// 2026-10-01: Mail's message frame logs it under Playwright 1.63.0, and the same frame in
// the same Chromium without Playwright logs nothing. Exact text, blank/srcdoc frames only.
const HARNESS_NOISE = /^Blocked script execution in 'about:(srcdoc|blank)' because the document's frame is sandboxed and the 'allow-scripts' permission is not set\.$/;

// Zero console errors is an assertion in every spec: each watched page's errors and
// uncaught exceptions (frames included) are checked when the test ends.
export const test = base.extend<{ consoleGuard: Guard }>({
  consoleGuard: async ({}, use) => {
    const errors: string[] = [];
    await use({
      watch(page, label) {
        page.on("console", (m) => {
          if (m.type() === "error" && !HARNESS_NOISE.test(m.text())) errors.push(`${label} console: ${m.text()} @ ${m.location().url}`);
        });
        page.on("pageerror", (e) => errors.push(`${label} pageerror: ${e.message}`));
      },
    });
    expect(errors, "console errors").toEqual([]);
  },
});

export { expect };
