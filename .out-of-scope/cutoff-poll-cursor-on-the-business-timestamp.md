# Polling cutoffs with a cursor on sessions_valid_after is out of scope

- Decided: 2026-10-19 · by devil (ruling REV, ADR 0025)
- Holds while: Postgres offers no commit-ordered change sequence and writers set `sessions_valid_after` from
  their own clocks

## The concept

Poll `auth_session_cutoffs` for rows newer than the newest `sessions_valid_after` already seen, to move less
data than a full reload.

## Why not

- It misses rows, measured (`rev-proof/cursor-miss.sh`). Transaction A starts first, so `now()` is its start
  time, and commits last. Poll 1 saw 1 row and set the cursor to `…42.551101`; A's row was `…42.050384`, and
  `> cursor` returned 0 rows, forever.
- The same miss happens for equal timestamps under `>`, for any writer on another clock (the gateway writes
  its own millisecond ISO), and for a value moved backward by a merge-duplicates upsert.
- A missed row is a revocation the operator believes in that does not exist.
- What replaces it: a full reload by keyset pages on `user_id` every 10 s, with a `Content-Range` count guard,
  swapped in whole.

## Prior requests

- Plan REV R2b, the poller as first written (2026-10-19).

## Reopen when

A DB-assigned, commit-ordered change sequence exists (`now()` is transaction start, and sequences are assigned
before commit, so Postgres provides neither), or the poll keeps a lookback window at least as long as the longest
write transaction plus a periodic full reload. The reload cost is 112 B/row per 10 s; revisit past 5,000 rows.
