import { request } from "@playwright/test";
import { PRISMATICA_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import {
  REGISTER_ACCEPTED,
  SPEC_PASSWORD,
  SUBJECTS,
  gateway,
  linkIn,
  login,
  register,
  resend,
  reservedAddress,
  waitForMails,
} from "../lib/account-mail";

// PR1 (PLAN §8.1): sign up, the confirmation mail arrives in Mailpit, a resend sends a second
// link; the first link is dead, the second confirms, and the password chosen at sign-up still
// signs in (C3: generate_link(signup) must not overwrite it). A taken address answers the same
// 202 and gets "you already have an account" (Q6). It needs AUTH_REQUIRE_EMAIL_VERIFICATION=true
// (C13); on a stack without it the register answer is 200 and the spec skips, saying so.
// Leaves its e2e-pr1-*@example.test accounts behind (no teardown yet; local backend only).

test.describe.configure({ mode: "serial" });

test("PR1 sign-up mails a link; a resend kills the first; the second confirms; the sign-up password works", async () => {
  test.setTimeout(180_000);
  const email = reservedAddress("pr1");
  const signUp = await register(email);
  test.skip(signUp.status === 200, "AUTH_REQUIRE_EMAIL_VERIFICATION is false on this stack: register confirmed the account at once (C13)");
  expect(signUp.status, String(signUp.body.message)).toBe(202);
  expect(signUp.body.message).toBe(REGISTER_ACCEPTED);
  const [first] = await waitForMails(email, SUBJECTS.confirm, 1);

  const unconfirmed = await login(email, SPEC_PASSWORD);
  expect({ status: unconfirmed.status, error: unconfirmed.body.error }, "an unconfirmed account cannot sign in, and is told why").toEqual({ status: 403, error: "email_not_confirmed" });

  const again = await resend(email);
  expect(again.status).toBe(202);
  const both = await waitForMails(email, SUBJECTS.confirm, 2);
  const second = both.find((m) => m.ID !== first!.ID)!;
  const oldLink = await linkIn(first!.ID, "confirm");
  const newLink = await linkIn(second.ID, "confirm");
  expect(newLink.token_hash).not.toBe(oldLink.token_hash);
  expect(newLink.type).toBe("signup");

  const tampered = await gateway("/api/auth/verify", { ...newLink, sig: `${newLink.sig.slice(0, -2)}AA` });
  expect(tampered.status, "a tampered signature is refused before GoTrue").toBe(410);
  expect(tampered.body.error).toBe("link_invalid");

  const stale = await gateway("/api/auth/verify", oldLink);
  expect(stale.status, "the first link died when the second was sent").toBe(410);

  const confirmed = await gateway("/api/auth/verify", newLink);
  expect(confirmed.status, String(confirmed.body.message)).toBe(200);
  const reused = await gateway("/api/auth/verify", newLink);
  expect(reused.status, "a link confirms once").toBe(410);

  const signIn = await login(email, SPEC_PASSWORD);
  expect(signIn.status, "the password chosen at sign-up survives the resend (C3)").toBe(200);
  expect(signIn.cookie, "the refresh token rides in the HttpOnly cookie").toMatch(/^prismatica_refresh=/);
});

test("PR1 a taken address answers the same 202 and is mailed 'you already have an account'", async () => {
  test.setTimeout(120_000);
  const email = reservedAddress("pr1");
  const first = await register(email);
  test.skip(first.status === 200, "AUTH_REQUIRE_EMAIL_VERIFICATION is false on this stack (C13)");
  const taken = await register(email, SPEC_PASSWORD, `pr_other_${Date.now()}`);
  expect({ status: taken.status, body: taken.body }).toEqual({ status: first.status, body: first.body });
  await waitForMails(email, SUBJECTS.exists, 1);
});

test("PR1 the confirm and reset pages send Referrer-Policy: no-referrer (C2)", async () => {
  const api = await request.newContext();
  try {
    for (const path of ["/auth/confirm/", "/auth/reset-password/"]) {
      const res = await api.get(`${PRISMATICA_URL}${path}`);
      expect(res.headersArray().filter((h) => h.name.toLowerCase() === "referrer-policy").map((h) => h.value), path).toEqual(["no-referrer"]);
    }
    const home = await api.get(PRISMATICA_URL);
    expect(home.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");
  } finally {
    await api.dispose();
  }
});
