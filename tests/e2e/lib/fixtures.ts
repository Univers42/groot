import { expect, test as base, type Page } from "@playwright/test";

type Guard = { watch(page: Page, label: string): void };

// Zero console errors is an assertion in every spec: each watched page's errors and
// uncaught exceptions (frames included) are checked when the test ends.
export const test = base.extend<{ consoleGuard: Guard }>({
  consoleGuard: async ({}, use) => {
    const errors: string[] = [];
    await use({
      watch(page, label) {
        page.on("console", (m) => {
          if (m.type() === "error") errors.push(`${label} console: ${m.text()} @ ${m.location().url}`);
        });
        page.on("pageerror", (e) => errors.push(`${label} pageerror: ${e.message}`));
      },
    });
    expect(errors, "console errors").toEqual([]);
  },
});

export { expect };
