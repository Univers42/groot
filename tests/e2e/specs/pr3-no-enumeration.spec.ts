import { expect, test } from "../lib/fixtures";
import { type Answer, ACCOUNT_MAIL_ACCEPTED, confirmedAccount, login, median, recover, resend, reservedAddress } from "../lib/account-mail";

// PR3 (PLAN §8.1, C5): /recover, /resend-verification and /login give a known and an unknown
// address the same status and body, and their median times differ by under 50 ms over 20
// tries each. 429s are waited out and not counted (gateway() in lib/account-mail.ts). /login
// spreads its tries over five addresses on each side (8 attempts each across both runs), because the gateway locks an address
// after 10 failures (AUTH_LOGIN_LOCKOUT_THRESHOLD) and a lockout answers 429 for both alike.
// Each mail phase has TRIES fresh addresses per side: registration plus one sample in each
// of at most two runs fits the shared /recover + /resend-verification cap of 3 per hour.
// Caveat: a timing test on a shared machine can false-fail under load. A surface that fails
// the timing bound is measured once more, and the message reports both medians of both runs.

const TRIES = 20;
const BOUND_MS = 50;
const KNOWN_PASSWORD_GUESS = "Not-The-Password-1!";

type Probe = (email: string) => Promise<Answer>;

async function measure(probe: Probe, known: readonly string[], unknown: readonly string[]) {
  const sides = { known: [] as Answer[], unknown: [] as Answer[] };
  for (let n = 0; n < TRIES; n += 1) {
    sides.known.push(await probe(known[n % known.length]!));
    sides.unknown.push(await probe(unknown[n % unknown.length]!));
  }
  return sides;
}

function shapes(answers: readonly Answer[]) {
  return [...new Set(answers.map((a) => JSON.stringify({ status: a.status, body: a.body })))];
}

async function sameAnswerSameTime(name: string, probe: Probe, known: readonly string[], unknown: readonly string[]) {
  const runs = [await measure(probe, known, unknown)];
  const gap = (run: (typeof runs)[number]) => Math.abs(median(run.known.map((a) => a.ms)) - median(run.unknown.map((a) => a.ms)));
  expect(shapes(runs[0]!.known), `${name}: one answer for every known try`).toHaveLength(1);
  expect(shapes(runs[0]!.unknown), `${name}: the unknown side answers exactly as the known side`).toEqual(shapes(runs[0]!.known));
  if (gap(runs[0]!) >= BOUND_MS) runs.push(await measure(probe, known, unknown));
  const report = runs.map((run, i) => `run ${i + 1}: known ${median(run.known.map((a) => a.ms)).toFixed(1)} ms, unknown ${median(run.unknown.map((a) => a.ms)).toFixed(1)} ms`).join("; ");
  expect(gap(runs[runs.length - 1]!), `${name}: median gap under ${BOUND_MS} ms (${report})`).toBeLessThan(BOUND_MS);
}

test("PR3 known and unknown addresses are indistinguishable at /recover, /resend-verification and /login", async () => {
  test.setTimeout(30 * 60_000);
  const known: string[] = [];
  const unknown: string[] = [];
  for (let n = 0; n < 5; n += 1) {
    known.push(await confirmedAccount("pr3"));
    unknown.push(reservedAddress("pr3-none"));
  }

  const first = await recover(known[0]!);
  expect(first.status).toBe(202);
  expect(first.body.message).toBe(ACCOUNT_MAIL_ACCEPTED);

  for (const [name, probe] of [["/recover", recover], ["/resend-verification", resend]] as const) {
    const mailKnown: string[] = [];
    const mailUnknown: string[] = [];
    for (let n = 0; n < TRIES; n += 1) {
      mailKnown.push(await confirmedAccount("pr3"));
      mailUnknown.push(reservedAddress("pr3-none"));
    }
    await sameAnswerSameTime(name, probe, mailKnown, mailUnknown);
  }
  await sameAnswerSameTime("/login", (email) => login(email, KNOWN_PASSWORD_GUESS), known, unknown);
});
