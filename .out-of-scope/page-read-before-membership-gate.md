# Reading a workspace's pages before the caller's membership is checked is out of scope

- Decided: 2026-11-23 · by devil (osionos #243 flat-read ruling)
- Holds while: the bridge reads pages with the service key and a non-member's refusal time is observable by the caller

## The concept

To speed up `/api/pages/all`, read the workspace's pages with a flat `osionos_pages?workspace_id=eq.W` query first, then check the caller's membership row afterwards and discard the rows on a 403. A proof issued after the read catches every revocation that lands before it, so it looks at least as strict as reading both in one statement.

## Why not

- Without a check before the read, the full read runs for anyone who names a workspace id. Measured on a synthetic 8,772-page workspace (scratch `pv243/p3/oracle.out`, psql, 3 runs):
  - non-member, today's embed: 0.30–1.32 ms;
  - non-member, read-first: 43.5–51.5 ms;
  - a workspace id that does not exist: 0.12–0.28 ms.

  The 403 latency therefore tells the caller whether the workspace exists and roughly how many pages it has. Each such request also moves 5.5 MB from PostgREST into the bridge for a caller who is refused.
- The fact that would have to change: a non-member's request does no work proportional to the workspace's size. For example, the read runs under the caller's own role with RLS, or the 403 is answered at a fixed latency independent of the read.

## Prior requests

- 2026-11-23 (coordinator, #243 option D): raised as the fastest of three measured read shapes. Ruled BLOCK. Gate → read → proof (D′) was cleared instead.

## Reopen when

Page reads stop costing a refused caller time that depends on the workspace's size, and a measurement shows non-member and non-existent-workspace refusals within 2 ms of each other at the median.
