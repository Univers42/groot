# `connect-src https: wss:` as the end state is out of scope

- Decided: 2026-11-23 · by devil (osionos #342 ruling, `scratch/csp342/RULING.md` §8)
- Holds while: issue #342 item 1 asks connect-src to name the origins the app talks to

## The concept

Write `connect-src 'self' https: wss:` by hand and stop there (design option A). No generator, no build-env coupling, nothing to drift.

## Why not

- It fails the issue's first item: a scheme-wide source restricts no host, so a script that got in can still send data to any https origin.
- It would be recorded as "connect-src done" while protecting nothing an attacker needs.

## Prior requests

- 2026-11-23 (design, #342): listed as option A.

## Reopen when

The server-supplied origins (LiveKit URL from the bridge's runtime `LIVEKIT_CLIENT_URL`, `scripts/bridge-rtc.mjs:27,82,247`) cannot be turned into build keys, and the user accepts scheme-wide connect-src in writing.
