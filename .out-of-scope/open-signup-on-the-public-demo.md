# Open signup on the public demo is out of scope

- Decided: 2026-10-17 · by devil (ruling on the public-site design, ADR 0013)
- Holds while: account and newsletter mail is sent by the gateway from the Titan box that also sends grobase
  prod's own mail, under one Kong bucket of 200/h

## The concept

The request: anyone who has the public link can create a Prismatica account and subscribe to the newsletter. The
existing controls bound abuse: Turnstile, email verification, and GoTrue's 30 mails an hour. No invite system and
no list of allowed addresses.

## Why not

The bound it relies on is not the one that applies.

- The signup confirm mail is sent by the gateway through grobase's `/email/v1/send`. GoTrue only produces the link
  (opposite-osiris `scripts/auth/account-mail.mjs` registerJob; `scripts/auth/email-api-mailer.mjs:2`).
  GOTRUE_RATE_LIMIT_EMAIL_SENT=30/h never counts it.
- The real ceiling is Kong's 10/min and 200/h on the gateway's single client IP (`email-api-mailer.mjs:9-11`).
  That is about 4800 mails a day to addresses an attacker chooses. The cost is one Turnstile solve per request,
  plus 3 per address per hour.
- Newsletter subscribe has no Turnstile at all (`scripts/auth-gateway.mjs:769-799`).
- The sender is devfast@archicode.codes on Titan, the same box GoTrue uses for grobase prod. Spam complaints or a
  suspension stop every grobase mail, and sender reputation does not come back in one step.
- What would have to change: account mail gets a sender of its own, with its own rate cap, so the demo's
  reputation is not prod's. Or the gateway enforces a daily mail ceiling below Titan's stated cap, and per-IP
  limits key IPv6 by /64.

## Prior requests

- 2026-10-17 (session cf5abf14): P3 of the public-site design proposed open signup, with a domain allowlist as the
  alternative.

## Reopen when

Signup and newsletter mail no longer share the prod Titan sender, or the gateway carries a daily mail ceiling
proven below Titan's cap by a test.
