import { OSIONOS_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { bridge, bridgeStatus, osionosSession } from "../lib/osionos-api";
import { openPortal } from "../lib/portal";
import { loginOrRegister, openOsionos } from "../lib/session";

// AC1 — a brand-new account, the way a visitor makes one: the landing's portal creates it,
// signs it in and hands it to osionos, which gives it a private workspace of its own. Its
// profile and a page it writes are still there in a fresh session, and the suite's other
// user cannot read that page. Leaves the account (the gateway has no delete; one per run,
// e2e-signup-<ms>@example.com) and nothing else: the page is deleted.

const PASSWORD = "E2e-Signup-Pass-2026!";

test("AC1 a new account signs up on the landing, lands in its own osionos workspace, and its data persists", async ({ browser, consoleGuard }) => {
  test.setTimeout(180_000);
  const stamp = Date.now();
  const email = `e2e-signup-${stamp}@example.com`;
  const username = `e2e_signup_${stamp}`;
  const context = await browser.newContext();
  const page = await context.newPage();
  consoleGuard.watch(page, "landing → osionos (new account)");

  const signUp = await openPortal(page, "Create account");
  await signUp.getByRole("textbox", { name: "Username" }).fill(username);
  await signUp.getByRole("textbox", { name: "Email" }).fill(email);
  await signUp.locator('input[name="password"]').fill(PASSWORD);
  await signUp.locator('input[name="confirmPassword"]').fill(PASSWORD);
  await signUp.getByRole("checkbox", { name: /I agree to the Terms/ }).check();
  await signUp.locator("form").getByRole("button", { name: "Create workspace account", exact: true }).click();
  await expect(page.getByText("Welcome to Prismatica!", { exact: true }), "the portal confirms the account").toBeVisible();
  // The portal closes itself after a sign-up (opposite-osiris b2ed21d); sign in from a fresh one.
  await expect(signUp, "the portal closes after the sign-up").toBeHidden();

  const signIn = await openPortal(page, "Sign in");
  await signIn.getByRole("textbox", { name: "Email" }).fill(email);
  await signIn.locator('input[name="password"]').fill(PASSWORD);
  await signIn.locator("form").getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL((url) => url.origin === new URL(OSIONOS_URL).origin, { timeout: 30_000 });
  const s = await osionosSession(page);

  const workspaces = ((await bridge(page, s, "GET", "/api/workspaces")).items ?? []) as { _id: string; role: string; ownerId: string }[];
  const owned = workspaces.filter((w) => w.ownerId === s.userId);
  expect(owned.map((w) => w._id), "one private workspace, the active one").toEqual([s.workspaceId]);

  // The osionos handle is the user's own choice, separate from the sign-up username, which
  // arrives as the display name (auth-gateway.mjs handoff payload `name`).
  const handle = `e2e_h_${stamp}`;
  await bridge(page, s, "PATCH", "/api/profile/me", { username: handle, headline: `e2e headline ${stamp}`, location: "e2e city" });
  const pageEntry = await bridge(page, s, "POST", "/api/pages", {
    workspaceId: s.workspaceId,
    title: `e2e-signup-page-${stamp}`,
    content: [{ id: `e2e-b-${stamp}`, type: "paragraph", content: `written by ${username}` }],
  });
  const pageId = String(pageEntry._id);
  try {
    // A fresh session for the same account: a new gateway login and handoff.
    const again = await openOsionos(browser, "", { token: await loginOrRegister({ email, password: PASSWORD, username }) });
    consoleGuard.watch(again.page, "osionos (new account, second session)");
    const s2 = await osionosSession(again.page);
    expect(s2.userId, "the same account").toBe(s.userId);
    expect(s2.workspaceId, "the same private workspace").toBe(s.workspaceId);
    const profile = await bridge(again.page, s2, "GET", `/api/profile/${s.userId}`);
    expect(profile.name, "the sign-up username is the display name").toBe(username);
    expect(profile.username).toBe(handle);
    expect(profile.headline).toBe(`e2e headline ${stamp}`);
    expect(profile.location).toBe("e2e city");
    const stored = await bridge(again.page, s2, "GET", `/api/pages/${pageId}`);
    expect(stored.title).toBe(`e2e-signup-page-${stamp}`);
    expect(JSON.stringify(stored.content)).toContain(`written by ${username}`);
    await again.context.close();

    // The suite's own user (another account) cannot read it.
    const other = await openOsionos(browser);
    const so = await osionosSession(other.page);
    expect(await bridgeStatus(other.page, so, `/api/pages/${pageId}`), "another account reading the page").toBeGreaterThanOrEqual(403);
    await other.context.close();
  } finally {
    await bridge(page, s, "DELETE", `/api/pages/${pageId}`);
    await context.close();
  }
});
