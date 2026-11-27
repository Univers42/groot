# A third-party CSP report sink is out of scope

- Decided: 2026-11-23 · by devil (osionos #342 ruling, `scratch/csp342/RULING.md` §8, C342-17–19)
- Holds while: reported URLs can carry tokens and signatures

## The concept

Point `report-uri` / `report-to` at a hosted collector instead of building one on the bridge.

## Why not

- A violation report carries the page URL and the blocked URL. The LiveKit socket URL carries `access_token` in its query, and signed media URLs (#233) carry their signature. A hosted sink would receive both, off-site.
- The bridge-hosted sink is blocked for its own reasons (unbounded counter keys, flood on a single-process bridge that beta shares with prod); a third party removes the load problem and keeps the disclosure one.

## Prior requests

- 2026-11-23 (design, #342): considered as the alternative to `POST /api/csp-report`.

## Reopen when

Client-side redaction of reported URLs is proven (C342-17a), and the user consents to reports leaving the deployment.
