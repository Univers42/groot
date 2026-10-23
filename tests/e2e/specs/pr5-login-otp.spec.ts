import { OSIONOS_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { LOGIN_CODE_SUBJECT, SPEC_PASSWORD, confirmedAccount, loginCodeIn, mailsTo, waitForMails } from "../lib/account-mail";
import { osionosSession } from "../lib/osionos-api";
import { openPortal } from "../lib/portal";

// PR5 (ADR 0006, the emailed sign-in code): after a correct password the portal asks for the
// 6-digit code grobase mails (read from Mailpit); a wrong code shows an error and keeps the
// step; a resend inside the gap sends no second mail; the right code lands in osionos signed in.
// It needs the gateway on AUTH_LOGIN_EMAIL_OTP=true and grobase on EMAIL_OTP_ENABLED=true. The
// stack is probed through the portal itself: a login that goes straight to osionos means the
// first is false, a "could not be sent" answer means the second is off, and the spec skips,
// saying which. No consoleGuard: a wrong code is a 401, which Chromium logs as a console error.
// Leaves its e2e-pr5-*@example.test account behind (local backend only).

const OSIONOS_ORIGIN = new URL(OSIONOS_URL).origin;

test("PR5 a wrong code is refused, a resend inside the gap sends nothing, the mailed code signs in", async ({ page }) => {
  test.setTimeout(180_000);
  const email = await confirmedAccount("pr5");
  const portal = await openPortal(page, "Sign in");
  await portal.getByRole("textbox", { name: "Email" }).fill(email);
  await portal.locator('input[name="password"]').fill(SPEC_PASSWORD);
  await portal.getByRole("button", { name: /Sign in securely/ }).click();

  const codeField = portal.getByLabel("Sign-in code");
  const outcome = await Promise.race([
    codeField.waitFor({ state: "visible", timeout: 30_000 }).then(() => "code" as const),
    page.waitForURL((url) => url.origin === OSIONOS_ORIGIN, { timeout: 30_000 }).then(() => "signed-in" as const),
  ]).catch(() => "neither" as const);
  test.skip(outcome === "signed-in", "AUTH_LOGIN_EMAIL_OTP is false on this stack: the password alone signed in");
  const stackText = (await portal.textContent()) ?? "";
  test.skip(outcome === "neither" && /sign-in code could not be sent/i.test(stackText), "grobase EMAIL_OTP_ENABLED is off on this stack: the gateway could not have a code sent");
  expect(outcome, `the code step never showed; the portal says: ${stackText.replace(/\s+/g, " ").slice(0, 200)}`).toBe("code");

  const [mail] = await waitForMails(email, LOGIN_CODE_SUBJECT, 1);
  const code = await loginCodeIn(mail!.ID);

  await codeField.fill("000000" === code ? "000001" : "000000");
  await portal.getByRole("button", { name: /^Verify/ }).click();
  await expect(portal.getByText("That code is not right."), "a wrong code shows an error").toBeVisible();
  await expect(codeField, "the code step stays").toBeVisible();

  await portal.getByRole("button", { name: "Resend code" }).click();
  await expect(portal.getByText("Wait a moment before asking for another code."), "a resend inside the gap is refused").toBeVisible();
  expect((await mailsTo(email, LOGIN_CODE_SUBJECT)).length, "the refused resend sent no second mail").toBe(1);

  await codeField.fill(code);
  await portal.getByRole("button", { name: /^Verify/ }).click();
  await page.waitForURL((url) => url.origin === OSIONOS_ORIGIN, { timeout: 30_000 });
  expect((await osionosSession(page)).userId, "signed in to osionos").not.toBe("");
});
