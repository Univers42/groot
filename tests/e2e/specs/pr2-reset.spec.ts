import { KONG_ANON_KEY, SHORT_RESET_TTL_SEC } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { bridgeStatus, osionosSession } from "../lib/osionos-api";
import { openOsionos } from "../lib/session";
import {
  NEW_PASSWORD,
  SPEC_PASSWORD,
  SUBJECTS,
  confirmedAccount,
  gateway,
  kong,
  linkIn,
  login,
  recover,
  totp,
  waitForMails,
} from "../lib/account-mail";

// PR2 (PLAN §8.1): a reset through the mailed link changes the password, and only the new one
// signs in. The session another browser holds is revoked where the plan says it is (C8, C9):
// its GoTrue refresh gets 4xx and the osionos bridge answers 401 for its token. Its access JWT
// stays valid up to 3600 s at signature-only services, the stated residual, so that is not
// asserted. A reused link, and an older link once a newer one was sent, are refused. Logout with
// the refresh cookie alone revokes it (C10). Variants: an expired link, on a stack started with
// AUTH_RESET_TOKEN_TTL_SEC=E2E_SHORT_RESET_TTL_SEC; a TOTP user (C4), with E2E_KONG_ANON_KEY.
// Not covered here: the access-log grep for token values (C2) reads container logs on the host.

test.describe.configure({ mode: "serial" });

async function resetLinks(email: string, count: number) {
  for (let n = 0; n < count; n += 1) expect((await recover(email)).status).toBe(202);
  const mails = await waitForMails(email, SUBJECTS.reset, count);
  return Promise.all(mails.map((m) => linkIn(m.ID, "reset-password")));
}

test("PR2 the newest reset link changes the password and signs every other session out", async ({ browser }) => {
  test.setTimeout(240_000);
  const email = await confirmedAccount("pr2");
  const other = await login(email, SPEC_PASSWORD);
  expect(other.status).toBe(200);
  const { context, page } = await openOsionos(browser, "", { token: String(other.body.access_token) });
  const session = await osionosSession(page);
  expect(await bridgeStatus(page, session, "/api/workspaces"), "the other browser's bridge token works before the reset").toBe(200);

  const [newest, older] = await resetLinks(email, 2);
  const stale = await gateway("/api/auth/reset-password", { ...older!, password: NEW_PASSWORD });
  expect(stale.status, "an older link dies once a newer one is sent").toBe(410);

  const done = await gateway("/api/auth/reset-password", { ...newest!, password: NEW_PASSWORD });
  expect(done.status, String(done.body.message)).toBe(200);
  expect(done.body.signed_out_everywhere, "logout?scope=global and the session cut-off both landed").toBe(true);
  expect((await gateway("/api/auth/reset-password", { ...newest!, password: NEW_PASSWORD })).status, "a link resets once").toBe(410);
  await waitForMails(email, SUBJECTS.changed, 1);

  expect((await login(email, SPEC_PASSWORD)).status, "the old password is dead").toBe(401);
  expect((await login(email, NEW_PASSWORD)).status, "the new password signs in").toBe(200);

  const refreshed = await gateway("/api/auth/refresh", {}, { cookie: other.cookie });
  expect(refreshed.status, "the other browser's refresh token was revoked (C9)").toBe(401);
  // The bridge caches each user's cut-off for 5 s (bridge-session-cutoff.mjs), so it is polled.
  await expect
    .poll(() => bridgeStatus(page, session, "/api/workspaces"), { message: "the bridge refuses the other browser's token (C8)", timeout: 15_000 })
    .toBe(401);
  await context.close();
});

test("PR2 logout with the refresh cookie alone revokes it (C10)", async () => {
  test.setTimeout(120_000);
  const email = await confirmedAccount("pr2");
  const signIn = await login(email, SPEC_PASSWORD);
  expect(signIn.cookie).toMatch(/^prismatica_refresh=/);
  const out = await gateway("/api/auth/logout", {}, { cookie: signIn.cookie });
  expect(out.status).toBe(200);
  expect(out.body.revoked).toBe(true);
  expect((await gateway("/api/auth/refresh", {}, { cookie: signIn.cookie })).status, "the old cookie no longer refreshes").toBe(401);
});

test("PR2 an expired reset link is refused", async () => {
  test.skip(!SHORT_RESET_TTL_SEC, "needs a stack started with AUTH_RESET_TOKEN_TTL_SEC=<n> and E2E_SHORT_RESET_TTL_SEC=<n>");
  test.setTimeout(120_000);
  const email = await confirmedAccount("pr2");
  const [link] = await resetLinks(email, 1);
  await new Promise((done) => setTimeout(done, (SHORT_RESET_TTL_SEC + 2) * 1000));
  const late = await gateway("/api/auth/reset-password", { ...link!, password: NEW_PASSWORD });
  expect(late.status).toBe(410);
  expect(late.body.error).toBe("link_expired");
  expect((await login(email, SPEC_PASSWORD)).status, "the password did not change").toBe(200);
});

test("PR2 a TOTP user resets after stepping up to aal2 (C4)", async () => {
  test.skip(!KONG_ANON_KEY, "E2E_KONG_ANON_KEY unset: run.sh reads KONG_PUBLIC_API_KEY from ./.env.local");
  test.setTimeout(180_000);
  const email = await confirmedAccount("pr2");
  const signIn = await login(email, SPEC_PASSWORD);
  const access = String(signIn.body.access_token);
  const factor = await kong("POST", "/auth/v1/factors", access, { factor_type: "totp", friendly_name: "pr2" });
  const secret = String((factor.totp as { secret?: string } | undefined)?.secret ?? "");
  const challenge = await kong("POST", `/auth/v1/factors/${String(factor.id)}/challenge`, access, {});
  await kong("POST", `/auth/v1/factors/${String(factor.id)}/verify`, access, { challenge_id: challenge.id, code: totp(secret) });

  const [link] = await resetLinks(email, 1);
  let answer = await gateway("/api/auth/reset-password", { ...link!, password: NEW_PASSWORD });
  expect(answer.status).toBe(401);
  expect(answer.body.error).toBe("mfa_required");
  expect(typeof answer.body.reset_ticket).toBe("string");
  const wrong = await gateway("/api/auth/reset-password", { reset_ticket: answer.body.reset_ticket, password: NEW_PASSWORD, code: "000000" });
  expect(wrong.body.error, "a wrong code keeps the ticket").toBe("mfa_invalid");
  answer = await gateway("/api/auth/reset-password", { reset_ticket: wrong.body.reset_ticket, password: NEW_PASSWORD, code: totp(secret) });
  expect(answer.status, `the reset completes: ${String(answer.body.message)}`).toBe(200);
  expect((await login(email, NEW_PASSWORD)).status).toBe(200);
});
