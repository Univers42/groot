# 0025. App sessions end at a polled per-user cutoff

- Status: accepted (O0 and P9 in the repo, not pushed); O2-O4, O7 and O9 are human-run and pending
- Date: 2026-10-19
- Deciders: owner, after a devil ruling (REV, 2026-10-19: PROCEED-WITH-CONDITIONS on the amended plan; the
  per-request prefetch (R2a) and the poller as first written (R2b) are BLOCK)

## Context

- A password reset signs the user out of GoTrue, but the `osionos_v1` tokens the bridge already minted stay
  valid until `exp` (30 days). The auth-gateway writes `public.auth_session_cutoffs(user_id, sessions_valid_after)`
  and nothing reads it, because the table existed only on `redesign/auth`. Every reset since the gateway
  shipped failed its cutoff write.
- One verifier covers every route: 56 call sites in `bridge-api.mjs` and 20 injected modules receive
  `verifySession: verifyAppSessionToken` (`bridge-api.mjs:4168-4187`), so the check belongs inside it.
- `sub` is `auth.users.id` on the only mint path (`createUserSession`, gateway `subject = user.id`).
- Measured (local `postgres:16-alpine` + `postgrest/postgrest:v12.2.3`, the pin in
  `docker-compose.track-binocle.yml:145`; scripts in the REV scratchpad `rev-proof/`):
  - A newest-seen cursor on `sessions_valid_after` misses rows. Transaction A starts first, so its `now()` is
    earlier, and commits last: poll 1 saw 1 row and set the cursor to `…42.551101`; A's row was `…42.050384`
    and `> cursor` returned 0 rows, for good.
  - An upsert that leaves the column to `DEFAULT now()` updates only the payload columns on conflict: logouts 2
    and 3 left the first timestamp (201, then 200 and 200, value unchanged), also with `missing=default`.
  - `resolution=merge-duplicates` with an older explicit value moved the row backward to 2026-01-01.
  - The gateway writes its own wall clock, millisecond ISO (`link-flows.mjs` `finish`), not `now()`.
  - A missing table answers 404 `42P01`; the per-request prefetch (4e5425ab) catches it and serves every user.
  - A literal `+` in a filter offset is a 400 (`22007`); `%2B` is 200. anon read is 401 `42501`. A cutoff for a
    user not in `auth.users` is a 409 (FK).
  - A full reload costs 1,000 rows = 111,883 B and 10,000 rows = 1,118,906 B, about 112 B/row.
  - One PostgREST round trip over Funnel costs 52 ms on a reused connection and 200 ms+ on a new one. Against
    the 263 ms workspace open (2026-10-18) a cold per-request lookup adds 20% to 76%.
  - Node 22 exits on an unhandled rejection (exit 1).
- grobase's `realtime_auto_trigger_on_create` arms `realtime_notify()` on every new public table, and that
  function sends full rows to any token the gateway accepts. aae116f4 relies on the runner's ORDERED_LAST
  cdc-off pass to drop it; a hand-applied table skips that pass.
- The desktop edition runs this bridge with a service key and a BaaS URL. Its migration list
  (`firstrun.mjs:35-45`) lacked the table, and GoTrue creates `auth.users` only later.

## Decision

- **Source of cutoffs.** A bridge-wide map refreshed by a paged full reload every 10 s, read synchronously by
  `verifyAppSessionToken`. No cursor on any column; keyset pages on `user_id`, a new Map swapped in one assignment.
- **Fail closed and loud.** Until the first load succeeds, and when the last success is older than 60 s,
  every token verification answers 503. Health reports `session_cutoffs: loading|fresh|stale|off`.
- **Table.** `models/auth-session-cutoffs.sql` with a monotonic BEFORE UPDATE trigger (`GREATEST(OLD, NEW)`,
  `SET search_path = pg_catalog`, not SECURITY DEFINER). Writers send an explicit timestamp from their host
  clock. `make models-grants-verify` gains e4 (a late older upsert leaves the newer value) and r-cutoffs
  (no `realtime_notify()` trigger on the table, by name).
- **Logout.** `POST /api/auth/bridge/logout` writes the cutoff and means "sign out everywhere".
- **Desktop.** `firstrun.mjs` `applyAuthSessionCutoffs` runs on every boot between the GoTrue health gate and
  PostgREST (`supervisor.mjs`), so the table exists before the bridge polls it.
- The captured token of 2026-10-18 dies by a cutoff row, not by rotating `OSIONOS_APP_SESSION_SECRET`.

## Alternatives

- **Per-request prefetch with a 5 s per-user cache (4e5425ab).** Adds 52-200 ms on a cold request (+20% to
  +76% on the open), load grows with active users (12 lookups/min each), and it fails open on a missing table
  and after a restart during an outage. Only its verifier half (the `iat_ms*1000 < cutoff` comparison and its
  +/-1 ms tests) is ported. See `.out-of-scope/per-request-session-cutoff-lookup.md`.
- **Poll with a newest-seen cursor.** Misses rows, measured. See
  `.out-of-scope/cutoff-poll-cursor-on-the-business-timestamp.md`.
- **Rotate `OSIONOS_APP_SESSION_SECRET`.** Kills the token and also signs every user out. Kept as the fallback if
  the cutoff route stalls (K6).
- **A jti deny-list.** Per-device revocation with more state; deferred (R5).

## Consequences

The conditions, from the ruling.

- **T1-T9 (table).** T1-T3 and the header notes T4 and T9 are in the repo (`make models-grants-verify`:
  42 passed, 0 failed). T5 prechecks, T6 apply, T7 postchecks and T8 backfill are human-run on prod; T6 drops the
  realtime trigger on this table only and never runs the repo-wide cdc-off file or `make migrate` on b2b.
- **P1-P16 (poller, osionos).** No cursor, count guard against truncation, 503 while loading or stale,
  `setTimeout` chain with every rejection caught, same-process writes applied as `max(existing, written)`,
  parameterized test through every injected module, `bridge.Dockerfile` COPY in the same commit as the gitlink
  bump, mutation counts in the commit body. P9 (desktop) is met here.
- **L1-L12 (logout).** Subject only from the verified token, a revoked token gets 401 and writes nothing, 204
  only after a 2xx write, explicit bridge-clock timestamp, app copy says "Sign out of all devices".
- **K1-K7 (the captured token).** Only after O7 shows `fresh`; every process holding the prod secret runs the
  poller or is stopped (the Fly app is unknown); the token is fully dead at K1 + 6 h (derived LiveKit tokens).
- Accepted residual: deleting a user cascades their cutoff away; an open SSE stream runs to its end; revocation
  lags 10 s, or 60 s during a poll outage.
- Clock skew: the bridge and the gateway share one host clock in compose, so skew is 0; a bridge on another
  host measures |delta| <= 1 s before it serves.

### Order

| Step | What | State |
|---|---|---|
| O0 | groot: T1-T3 and P9 on a branch, `make models-grants-verify` green | done locally, not pushed |
| O1 | opposite-osiris: record whether the prod gateway is >= 47ca59e | open, no code change |
| O2 | prod T5 prechecks (read-only) | pending, human-run |
| O3 | prod T6 apply, then T7 postchecks | pending, human-run |
| O4 | prod T8 backfill, count recorded | pending, human-run |
| O5 | osionos: poller, logout and app parts, P14-P16 and L11 green | open |
| O6 | groot: gitlink bump with the `bridge.Dockerfile` COPY, `public-verify` health check | open |
| O7 | prod bridge deploy, precheck from inside the container, previous tag kept | pending, human-run |
| O8 | prod app bundle deploy | open |
| O9 | K1-K5, kill the captured token | pending, human-run |
| O10 | records: this ADR and the two `.out-of-scope` files | done |

The table must exist on prod before any bridge enforces, and every bridge holding the secret must enforce
before the token is called killed.
