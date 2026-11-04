import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium, firefox, type BrowserContext } from "@playwright/test";

export const FIREFOX_STORE = "/tmp/e2e-home/reach-firefox-store";

// open BROWSER TRUSTED — a real browser with its own store. Chromium reads $HOME/.pki/nssdb, where
// the image's entrypoint put the CA, so an untrusted one gets an empty HOME. Firefox reads its
// profile. No ignoreHTTPSErrors anywhere: a certificate problem must fail the test.
export async function open(browserName: string, trusted: boolean): Promise<{ context: BrowserContext; close(): Promise<void> }> {
  const dir = mkdtempSync(join(tmpdir(), "reach-"));
  const launch = { headless: true, viewport: { width: 1440, height: 900 } };
  let context: BrowserContext;
  if (browserName === "firefox") {
    if (trusted) cpSync(FIREFOX_STORE, dir, { recursive: true });
    context = await firefox.launchPersistentContext(dir, launch);
  } else {
    const env = trusted ? process.env : { ...process.env, HOME: dir };
    context = await chromium.launchPersistentContext(join(dir, "profile"), { ...launch, env: env as Record<string, string> });
  }
  return {
    context,
    async close() {
      await context.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
