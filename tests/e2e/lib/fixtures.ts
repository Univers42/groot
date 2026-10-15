import { expect, test as base, type ConsoleMessage, type Page } from "@playwright/test";

type Guard = { watch(page: Page, label: string, expected?: RegExp): () => void };

// Playwright's own injected scripts are refused by a sandboxed frame without allow-scripts,
// and Chromium logs that as the page's error (microsoft/playwright#33343). Measured
// 2026-10-01: Mail's message frame logs it under Playwright 1.63.0, and the same frame in
// the same Chromium without Playwright logs nothing. Exact text, blank/srcdoc frames only.
const HARNESS_NOISE = /^Blocked script execution in 'about:(srcdoc|blank)' because the document's frame is sandboxed and the 'allow-scripts' permission is not set\.$/;

// Zero console errors is an assertion in every spec: each watched page's errors and
// uncaught exceptions (frames included) are checked when the test ends. watch returns the
// call that stops watching, for a spec whose cleanup (not under test) deletes what the page
// still shows: the page refetching it logs a 404 that only remote-backend latency lets land.
// `expected` matches one error the test itself causes, as "<text> @ <url>": Chromium logs every
// 4xx answer to fetch as an error, so a spec that mocks a refusal names that one answer.
export const test = base.extend<{ consoleGuard: Guard }>({
  consoleGuard: async ({}, use) => {
    const errors: string[] = [];
    await use({
      watch(page, label, expected) {
        const onConsole = (m: ConsoleMessage) => {
          const seen = `${m.text()} @ ${m.location().url}`;
          if (m.type() === "error" && !HARNESS_NOISE.test(m.text()) && !expected?.test(seen)) errors.push(`${label} console: ${seen}`);
        };
        const onPageError = (e: Error) => errors.push(`${label} pageerror: ${e.message}`);
        page.on("console", onConsole);
        page.on("pageerror", onPageError);
        return () => {
          page.off("console", onConsole);
          page.off("pageerror", onPageError);
        };
      },
    });
    expect(errors, "console errors").toEqual([]);
  },
});

export { expect };
