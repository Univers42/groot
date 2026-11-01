# 0035. Grobase email OTP is enabled live for the bridge sudo step-up

- Status: accepted (devil: PROCEED-WITH-CONDITIONS)
- Date: 2026-10-31
- Deciders: devil (ruling), owner (lives with it)

## Context

- Live `/api/account/sudo/email` answers 503: tenant-control logs "EMAIL_OTP_ENABLED off — /v1/auth/otp/* not mounted" (measured 2026-10-31 by the parent session).
- The flag mounts 4 routes (`apps/grobase/src/control-plane/internal/loginotp/handler.go:30-35`).
- `otp/request` is key-auth + acl baas-admin in Kong (`infra/docker/services/kong/conf/kong.yml:547-580`); measured no-key POST → 401. Only service_role can make a code exist.
- Both escrow routes reject without a proof bound to the email (`loginotp/escrow.go:90`, `:114`; `verifyProof` checks aud `otp-proof` and `otp==lower(email)`, `escrow.go:34-50`).
- The edge is on the public internet: Tailscale Funnel ON for baas.tail10f2ea.ts.net :443/:8443/:10000, Kong bound 127.0.0.1:8000 behind it (measured 2026-10-31).
- KEY_HASH_PEPPER is unset and is also the tenant API key HMAC key (`control-plane/internal/tenants/keys_hash.go:56`); setting it invalidates every key.
- Unknown when written: whether the 5-attempt cap is per code row or per email; whether a proof JWT (HS256, GOTRUE_JWT_SECRET) is rejected as a bearer by PostgREST/bridge.

## Decision

EMAIL_OTP_ENABLED=true in /opt/grobase/.env; only mini-baas-tenant-control is recreated, under the compose file set it already runs with. KEY_HASH_PEPPER stays unset.

## Alternatives considered

- **Set KEY_HASH_PEPPER too**: breaks every tenant API key (`keys_hash.go:56`); needs a key-rotation plan of its own (see `baas-key-rotation` memory: rotation 401s baked frontends).
- **Leave it off**: step-up stays 503; Phase 1 /machine cannot ship.
- **Kong-block verify/escrow from the Funnel**: the bridge reaches verify through the same edge; not worth a second routing surface for a 5-attempt, 300 s, service-issued code.

## Consequences

- Public surface grows by verify + escrow (proof-gated). Online guessing: 5 tries per issued code over 10^6 codes.
- Unpeppered OTP hashes: a DB reader can crack a live code within 300 s — accepted; a DB reader already owns more.
- The 42ctl `auth login --email` flow becomes reachable; its request leg still needs service_role.
- Reversal: remove the line, recreate tenant-control with the same file set.
- Follow-up: pepper split (separate OTP pepper from key HMAC) — untracked, owner to file.

## Outcome (2026-10-31)

All seven conditions were checked on the VM:
- `.env` backed up as `/opt/grobase/.env.bak-otp-20261031`. The stale mailpit `SMTP_HOST/PORT/SECURE` block was removed; the titan block below it was already the effective value.
- tenant-control was recreated with the compose files it already used (`docker-compose.yml` and `orchestrators/compose/docker-compose.remote-access.yml`), with the same image (`e4a76f914aaf`).
- tenant-control's env: `EMAIL_OTP_ENABLED=true`, `SMTP_HOST=smtp.titan.email`, `KEY_HASH_PEPPER` unset. The log reads "email login OTP enabled".
- No-key calls through the public edge: `otp/request`, `PUT escrow` and `escrow/fetch` each answer 401.
- The gateway anon and service keys answer 200.
- The bridge ties the proof to the session's own address: `bridge-account-sudo.mjs:155,165`, with tests in `bridge-account-sudo.test.mjs:252` and `bridge-account-otp.test.mjs:47` (49/49 pass).
- A full step-up with dev.pro.photo, from the live web app and from the desktop app, opened `/machine` (ADR-0034, ADR-0036).
