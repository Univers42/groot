import { expect, test } from "../lib/fixtures";
import { SUBJECTS, gateway, linkIn, mailsTo, recover, register, resend, reservedAddress, waitForMails } from "../lib/account-mail";

// PR4 (PLAN §8.1, C7): /recover, /resend-verification and a verifying /register share one
// per-address bucket of 3 an hour, taken before any lookup. With the bucket filled by
// alternating requests, the 4th answers exactly as the others did and sends no mail. The 4th
// is a /recover on a confirmed account, the request that would otherwise send a reset mail,
// so "no mail" is not vacuous. A fresh address per run keeps earlier runs' counts out.

const SETTLE_MS = 5_000;

const mailCount = async (email: string) => (await mailsTo(email, SUBJECTS.reset)).length + (await mailsTo(email, SUBJECTS.confirm)).length;

test("PR4 the 4th account-mail request in an hour for one address answers the same and sends nothing", async () => {
  test.setTimeout(180_000);
  const email = reservedAddress("pr4");
  const signUp = await register(email);
  const fill = [resend, recover];
  if (signUp.status === 202) {
    // A verifying /register took the first slot; its link confirms the account (no slot).
    const [mail] = await waitForMails(email, SUBJECTS.confirm);
    expect((await gateway("/api/auth/verify", await linkIn(mail!.ID, "confirm"))).status).toBe(200);
  } else {
    expect(signUp.status, String(signUp.body.message)).toBe(200);
    fill.push(resend);
  }
  const answers = [];
  for (const send of fill) answers.push(await send(email));
  await expect.poll(async () => (await mailsTo(email, SUBJECTS.reset)).length, { message: "the uncapped /recover mailed", timeout: 30_000 }).toBe(1);
  await new Promise((done) => setTimeout(done, SETTLE_MS));
  const before = await mailCount(email);

  const capped = await recover(email);
  expect(capped.status).toBe(202);
  for (const answer of answers) expect({ status: answer.status, body: answer.body }).toEqual({ status: capped.status, body: capped.body });
  await new Promise((done) => setTimeout(done, SETTLE_MS));
  expect(await mailCount(email), "the capped request sent no mail").toBe(before);
});
