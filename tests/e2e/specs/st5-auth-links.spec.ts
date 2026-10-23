import type { Page, Request } from "@playwright/test";
import { expect, test } from "../lib/fixtures";

// ST5 — the pages the account emails open (ADR 0006). The built site, with the gateway answered by
// route mocks: the token stays in the fragment, leaves the address bar on arrival, and goes to
// the gateway once; each outcome shows its next step. The gateway's own behaviour is pr1–pr4's.
const CONFIRM = { token_hash: "pkce_st5confirm", type: "signup", exp: "4102444800", sig: "c3Q1LXNpZw" };
const RESET = { ...CONFIRM, token_hash: "pkce_st5reset", type: "recovery" };
const STRONG = "Arlet!2026x";

// Chromium logs a mocked refusal as "Failed to load resource"; only that answer, from that endpoint.
const refusal = (status: number, path: string) =>
  new RegExp(`^Failed to load resource: the server responded with a status of ${status} \\(.+\\) @ https?://[^/]+/api/auth/${path}$`);

function fragment(fields: Record<string, string>): string {
  return `#${new URLSearchParams(fields)}`;
}

async function answer(page: Page, path: string, replies: Array<[number, Record<string, unknown>]>) {
  const seen: Request[] = [];
  await page.route(`**/api/auth/${path}`, async (route) => {
    seen.push(route.request());
    const reply = replies[Math.min(seen.length, replies.length) - 1];
    if (!reply) throw new Error(`no reply configured for ${path}`);
    const [status, body] = reply;
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
  });
  return seen;
}

test.describe("ST5 account-email landing pages", () => {
  for (const path of ["/auth/confirm/", "/auth/reset-password/"]) {
    test(`${path} sends no Referer anywhere`, async ({ page }) => {
      const response = await page.goto(path);
      expect(response?.headers()["referrer-policy"]).toBe("no-referrer");
    });
  }

  test("a confirmation link is posted once, leaves the address bar, and offers sign-in", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "confirm");
    const seen = await answer(page, "verify", [[200, { message: "Your email is confirmed. You can sign in now." }]]);
    await page.goto(`/auth/confirm/${fragment(CONFIRM)}`);
    await expect(page.getByRole("status")).toHaveText("Your email is confirmed. You can sign in now.");
    expect(page.url()).not.toContain("token_hash");
    expect(seen).toHaveLength(1);
    expect(seen[0]?.postDataJSON()).toEqual(CONFIRM);
    await page.getByRole("main").getByRole("button", { name: "Sign in" }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
  });

  test("a refused confirmation link opens the new-link form", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "confirm-refused", refusal(410, "verify"));
    await answer(page, "verify", [[410, { error: "link_used", message: "This link was already used or replaced by a newer one. Ask for a new link." }]]);
    await page.goto(`/auth/confirm/${fragment(CONFIRM)}`);
    await expect(page.getByRole("status")).toContainText("already used");
    await page.getByRole("button", { name: "Send a new link" }).click();
    const portal = page.getByRole("dialog");
    await expect(portal.getByRole("button", { name: "Send a new link" })).toBeVisible();
    await expect(portal.locator("#portal-password")).toBeHidden();
  });

  test("a reset that needs the authenticator code continues with the ticket, not the link", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "reset", refusal(401, "reset-password"));
    const seen = await answer(page, "reset-password", [
      [401, { error: "mfa_required", message: "Enter the 6-digit code from your authenticator app.", reset_ticket: "st5-ticket" }],
      [200, { message: "Your password was changed. Sign in again with the new password.", signed_out_everywhere: true }],
    ]);
    await page.goto(`/auth/reset-password/${fragment(RESET)}`);
    expect(page.url()).not.toContain("token_hash");
    await page.getByRole("textbox", { name: "New password", exact: true }).fill(STRONG);
    await page.getByRole("textbox", { name: "Repeat the new password", exact: true }).fill(STRONG);
    await page.getByRole("button", { name: "Change password" }).click();
    const code = page.getByLabel("Code from your authenticator app");
    await expect(code).toBeFocused();
    await code.fill("123456");
    await page.getByRole("button", { name: "Change password" }).click();
    await expect(page.getByRole("status")).toContainText("Your password was changed");
    await expect(page.getByRole("main").getByRole("button", { name: "Sign in" })).toBeVisible();
    expect(seen.map((request) => request.postDataJSON())).toEqual([
      { ...RESET, password: STRONG },
      { reset_ticket: "st5-ticket", password: STRONG, code: "123456" },
    ]);
  });

  test("Forgot password? from sign-in asks for a reset link and says the same thing for any address", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "recover");
    const accepted = "If an account can receive mail at that address, a message is on its way. Check your inbox.";
    const seen = await answer(page, "recover", [[202, { message: accepted }]]);
    await page.goto("/");
    await page.getByRole("banner").getByRole("button", { name: "Sign in" }).click();
    const portal = page.getByRole("dialog");
    await portal.getByRole("button", { name: "Forgot password?" }).click();
    await portal.getByRole("textbox", { name: "Email", exact: true }).fill("ines@arlet.example.com");
    await portal.getByRole("button", { name: "Send reset link" }).click();
    await expect(portal.getByText(accepted)).toBeVisible();
    expect(seen[0]?.postDataJSON()).toMatchObject({ email: "ines@arlet.example.com" });
  });
});
