# Looking the session cutoff up per request is out of scope

- Decided: 2026-10-19 · by devil (ruling REV, ADR 0025)
- Holds while: the bridge is reached from PostgREST over a link that costs tens of milliseconds, and the
  in-window cutoff set fits a paged full reload

## The concept

Commit 4e5425ab: on each authenticated request, fetch that user's `auth_session_cutoffs` row through
PostgREST and cache it for 5 s, so a revocation lands without a poll.

## Why not

- It is hot-path I/O: one round trip per active user every 5 s, 52 ms on a reused connection and 200 ms+ on
  a new one over Funnel. The 6 lanes of a workspace open share one in-flight lookup and all wait for it,
  which is +20% to +76% on a 263 ms open. A hung BaaS holds every request for up to 8 s
  (`BAAS_FETCH_TIMEOUT_MS`).
- Load scales with active users (12 lookups/min each); the poller is 6/min in total.
- It fails open on a missing table (404 `42P01` is caught, every user is served) and after a restart during
  an outage. The deploy order becomes invisible.
- What was kept: the verifier comparison and its +/-1 ms tests.

## Prior requests

- 4e5425ab on osionos `redesign/bridge-auth` (2026-10-18).

## Reopen when

The bridge reaches PostgREST at 10 ms p95 or better (co-located, measured), and the in-window cutoff set
exceeds about 1 MB per full reload (about 10k rows). Even then it must fail closed on a missing table.
