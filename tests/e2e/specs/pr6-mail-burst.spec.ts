import { expect, test } from "../lib/fixtures";
import { SPEC_PASSWORD, SUBJECTS, registerNow, reservedAddress, waitForMails } from "../lib/account-mail";

// PR6: a burst past Kong's 10 mails a minute is delayed, not lost. The gateway is the one client
// of /email/v1 (kong.yml, email-routes), so any 11 sign-ups in a minute meet that limit, and a
// mail refused there used to be dropped after a 10 s retry inside the same window. Kong's window
// is the wall-clock minute, so the burst starts at :05 and cannot straddle two windows, which
// would let every mail through and prove nothing. 12 is the gateway's own /register allowance a
// minute (RATE_LIMITS in auth-gateway.mjs). It needs AUTH_REQUIRE_EMAIL_VERIFICATION=true; on a
// stack without it the register answer is 200 and the spec skips, saying so.
// Leaves its e2e-pr6-*@example.test accounts behind (local backend only).

const BURST = 12;
const WINDOW_MS = 60_000;
const BURST_AT_MS = 5_000;
const DELIVERY_BOUND_MS = 2 * WINDOW_MS;

test("PR6 every mail in a burst past Kong's limit arrives", async () => {
  test.setTimeout(WINDOW_MS + DELIVERY_BOUND_MS + 30_000);
  await new Promise((done) => setTimeout(done, (WINDOW_MS + BURST_AT_MS - (Date.now() % WINDOW_MS)) % WINDOW_MS));
  const stamp = Date.now();
  const addresses = Array.from({ length: BURST }, () => reservedAddress("pr6"));
  const answers = await Promise.all(addresses.map((email, n) => registerNow(email, SPEC_PASSWORD, `pr6_${stamp}_${n}`)));
  test.skip(answers[0]!.status === 200, "AUTH_REQUIRE_EMAIL_VERIFICATION is false on this stack (C13)");
  expect(answers.map((answer) => answer.status)).toEqual(Array(BURST).fill(202));
  await Promise.all(addresses.map((email) => waitForMails(email, SUBJECTS.confirm, 1, DELIVERY_BOUND_MS)));
});
