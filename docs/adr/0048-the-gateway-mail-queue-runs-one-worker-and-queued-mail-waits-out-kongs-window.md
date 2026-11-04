# 0048. The gateway's mail queue runs one worker, and queued mail waits out Kong's window

- Status: accepted (devil, PROCEED-WITH-CONDITIONS on 2026-11-04)
- Date: 2026-11-04
- Deciders: devil (the ruling and its conditions); the builder lands it; the owner lives with the mail latency.

## Context

Line numbers are on prismatica `3423773` and groot `e037730c`.

- `send` retries a 429 once, capped at 10 s (`scripts/auth/email-api-mailer.mjs:18,26-30,60-63`). Kong's minute window can
  have up to 60 s left, so the retry lands in the same window and the mail is lost.
- Route `email-routes` allows 10/min and 200/h per IP with `policy: local`
  (`apps/grobase/infra/docker/services/kong/conf/kong.yml`, `email-routes`). The gateway is its only client.
- Kong 3.8.0 sends Retry-After unless `hide_client_headers` is set, and the route does not set it
  (`kong/plugins/rate-limiting/handler.lua:181,195`, read at tag 3.8.0). The value is
  `window - floor(elapsed)`, so it already rounds up. A 429 is not counted (the increment comes after the `stop` return).
- Production sign-in awaits a mail through this same bucket: `AUTH_LOGIN_APPROVE_LINK: "true"`
  (`infrastructure/compose/public-b2b.yml:70`), `loginApprove.begin` (`scripts/auth-gateway.mjs:833`),
  `await sendApprovalMail` (`scripts/auth/login-approve.mjs:95`). A failed send answers 503.
- The queue runs two jobs at once and has no per-address order (`scripts/auth-gateway.mjs:483-486`,
  `scripts/auth/work-queue.mjs:36-63`). `registerJob` checks `profiles.emailExists`, then calls generate_link, then
  creates the profile (`scripts/auth/account-mail.mjs:78-83`), so two jobs for one address can both pass the check.
- GoTrue v2.188.1 on an unconfirmed user merges the second caller's metadata, leaves the password, and replaces the
  token, so the first link dies (`internal/api/mail.go:203-231`, `internal/models/user.go:228-241`,
  `internal/models/one_time_token.go:135-138`, read at tag v2.188.1; the build pin is
  `apps/grobase/infra/docker/services/gotrue/Dockerfile`).
- Every HTTP step of a job has a timeout: GoTrue 8 s (`scripts/auth/gotrue-api.mjs`), SDK 15 s
  (`vendor/grobase-js/lib/core/http.js:28`), mail 30 s, DNS 3.5 s (`scripts/auth-gateway.mjs:115,200`). Redis commands have
  none (`scripts/auth/redis-store.mjs`, `#send`), but `accept` and every rate limit stall on the same call.
- The daily cap is taken once per message before the retry, under one store key, and a refusal skips the retry
  (`scripts/auth/email-api-mailer.mjs:57-58`, `scripts/auth/mail-daily-cap.mjs:42`). The cap is 200 by default and 50 on the
  public overlay (`mail-daily-cap.mjs:26`, `docker-compose.public.yml:79`), so Kong's 200/h cannot fill in production first.
- Measured by simulation, not on a live stack: virtual clock, a Kong double built from the source above, the real
  `createWorkQueue` and `createAccountMail`, constant send latency.
  - Two /register on one fresh address, 0 to 60 ms apart, two workers: two confirm mails, no "already have an account",
    first link dead, metadata from the second caller. One worker: one of each, metadata intact.
  - Backlog of 60 with one login mail every 31 s, 9 s sends: two workers lost 3 of 13 login mails and took 17 Kong 429s;
    one worker lost 0 of 18 and took none. At 3 s sends both lost 5 of about 12.
  - 24 mails then one sign-in alert, 11 s sends: alert after 154 s on two workers, 275 s on one.
  - 8 addresses with 3 requests each, 11 s sends: the plan's chain drains in 187 s against 143 s unchained, and a head
    job that never settles stops all mail. Serialising by key inside the queue drains in 143 s.
  - Plan 1 with two workers and no serialisation, two /recover for one address in a full window: the newest mail held
    the dead link in 3 of 30 timings; 0 of 30 on one worker.
- Unknown when this was written: whether the race is what failed PR1 in CI (only the timing fits, no gateway log);
  whether Retry-After survives the WAF on the vault42 path; Titan's send time today (9-13 s was measured on 2026-10-17);
  peak real demand on the queue.

## Decision

The queued senders (account mail, the sign-in alert, the account-created notice) wait out Kong's window with one retry.
Live senders keep the 10 s cap. The wait is a per-call option on the one mailer behind the one suppression point.

The gateway's mail queue runs one worker. That serial order is what makes `registerJob`'s check-then-act safe in the
one gateway process, and it keeps queued mail below Kong's limit while a send takes more than 6 s.

Both changes land in one pin, and the defect is fixed rather than only reported.

## Alternatives considered

- **A promise chain per address, each job awaiting the previous one in its queue slot (the plan)**: no deadlock (FIFO,
  `work-queue.mjs:51-63`), but an idle job holds a worker, so an attacker's paired requests cost the throughput the
  chain was meant to keep, and a job that never settles stops all mail. Refused in `.out-of-scope/`.
- **Serialise by key inside `createWorkQueue`**: holds no worker and kept 143 s in the model. It is the fallback if demand
  proves one worker too slow; today it is about 10 lines against one, for a demand nobody has measured. At 5 mails a
  minute the whole daily cap goes in 10 to 40 minutes.
- **Pace PR1 only**: hides a defect that the model reproduces on the real code. PR1 stays back to back.
- **A second mailer instance (the plan)**: the cap would hold, but two wrappers make two suppression points, against
  `scripts/auth-gateway.mjs:466`, and fail the guard at `tests/unit/auth/gateway-verification-exempt.test.ts:156-160`.
- **Raise Kong's limit**: changes grobase for one app's bursts and removes the ceiling on a leaked service key.

## Consequences

Verdict: PROCEED-WITH-CONDITIONS. The conditions are acceptance criteria for the builder.

1. `concurrency: 1` at `scripts/auth-gateway.mjs:485`, with a comment naming what depends on it. `work-queue.mjs:7` changes
   in the same commit.
2. The red test runs through the real gateway process (`gateway-harness`), so raising the number back to 2 fails it. It
   fails at 2 workers before the change. PR1 stays back to back and also asserts exactly one confirm mail.
3. Plan 1 and condition 1 land in one pin. Plan 1 alone can deliver the dead link last.
4. One mailer and one `withExemptSuppression`, with the wait as a forwarded per-call option. The guard at
   `gateway-verification-exempt.test.ts:156-160` stays at least as strict.
5. The 10 s path is unchanged: `tests/unit/auth/email-api-mailer.test.ts:51,127` pass unedited, and any margin is on the
   queued path only.
6. The `Caveat:` in `email-api-mailer.mjs:9-11` is rewritten in the same commit and names: the hourly bucket still loses
   mail after one wait; a newsletter mail inside a queued job keeps the 10 s cap; login mail keeps headroom only while a
   send takes more than 6 s; a link loses up to 120 s of its life to an in-job wait (Kong rounds Retry-After up, so no margin was added); a queued alert can wait behind a backlog,
   9 to 36 minutes at a daily cap of 50 to 200.
7. pr6 is shown red on today's gateway before it counts as proof. It sends 12 mails, not 14, which still passes Kong's 10.

What this makes harder: a burst drains about 1.8 times slower on one worker. Reverse it the day the audit log shows real
sustained demand above 5 mails a minute, by moving to the keyed queue above, never by raising the number alone, which
reopens the race. If `emailsvc` drops under 6 s a send, the login headroom goes, and that needs its own decision.
