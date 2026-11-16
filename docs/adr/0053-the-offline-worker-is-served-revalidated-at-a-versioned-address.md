# 0053. The offline worker is served revalidated, at a versioned address

- Status: accepted with conditions. Devil ruling: PROCEED-WITH-CONDITIONS W1–W6
  (`.claude/agent-memory/devil/osionos-sw-update-verdict.md`).
- Date: 2026-11-16
- Deciders: devil (risk ruling). The osionos web owner lives with it.

## Context

Code is osionos `ce74ab157` (`fix/stale-worker-update`, on `develop`).

- nginx served `/sw.js` with `Cache-Control: max-age=31536000, public, immutable`. Firefox does not re-check
  an immutable worker script, so a Firefox that registered the worker on 2026-10-30 kept that day's bytes
  after `sw.js` was fixed on 2026-11-16 to stop answering navigations.
- Under Firefox 158 Local Network Access, a navigation answered by a worker keeps the page in the public
  zone, and every call to the bridge on `:10000` is then held or cancelled. The user saw "The connection to
  the server is not stable", "This page couldn't be loaded" on each page open, and "NetworkError when
  attempting to fetch resource" under every database engine. The proxy log showed the 499s only for that
  browser; a fresh Firefox 158 profile cancelled about 3 requests in 7,947.
- The devil measured (`devil-ngx`, `devil-loop` probes): `location = /sw.js` matches `/sw.js?v=2`; a
  conditional request answers 304; a worker script whose bytes change on every fetch reloads an uncapped
  page 14 times in 15 s.
- The sign-in handoff token is single use (`bridge-api.mjs:2257`), so a reload during its consume burns the
  sign-in.

## Decision

The worker script is never cached without revalidation, and it is registered at an address no browser holds
an immutable copy of.

- nginx: `location = /sw.js` answers `Cache-Control: no-cache`.
- The app registers `/sw.js?v=2` (`registerAppWorker`, `src/shared/lib/service-worker/appWorker.ts`).
- A page that was loaded under any other worker reloads once when the new worker takes control.
- W1: the reload is capped: none within 10 s of the last one (`sessionStorage`, `osionos:worker-reloaded-at`).
- W2: no reload after a keystroke or paste in this page.
- W3: no reload while `bridge_token` is in the address.
- W4: a rollback rolls forward. The bare `/sw.js` address is never registered again: a Firefox holding the
  immutable entry would get the 2026-10-30 bytes back until 2027-11.
- W5: after deploy, `curl -sI 'https://<origin>:8443/sw.js?v=2'` shows `no-cache` and no `immutable`.
- W6: the affected browser shows the `?v=2` worker and its bridge cancel rate falls to about the
  fresh-profile level over at least one hour.

## Alternatives considered

- **Only fix the header**: a browser holding the immutable entry never asks again, so it never sees the new
  header. Rejected.
- **Unregister every worker from the page**: removes offline start for everyone to repair one cache entry,
  and the next registration of `/sw.js` reads the same entry. Rejected.
- **Ask users to clear site data**: works, and is the workaround until the deploy. Not a repair.

## Consequences

- Every returning browser reloads once after the deploy, and again after any later change to `sw.js`.
- A draft typed in the last 250 ms before that reload can be lost when the page has not finished its first
  sync (`usePageSync.ts:262` returns early); W2 covers a page the user has typed in.
- The next address change is `?v=3`. The number is part of the contract: reusing an address that was ever
  served immutable repeats this fault.
- Not measured: whether Chromium ever kept the old worker. The fix was checked in both (evidence
  `swupd2-firefox158.out`, `swupd2-chrome.out`).
