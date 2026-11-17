# Sanitizing the README HTML a second time in the bridge is out of scope

- Decided: 2026-11-17 · by devil (ADR 0058)
- Holds while: the bridge and the client do not share one parser module.

## The concept

Run a second HTML sanitizer over the README in the bridge projection, as defence in depth.

## Why not

- A second parser creates a parser differential: what the bridge judges safe is not what the client parses.
- The client parser is the one that renders, so it is the one that must be exact (ADR 0058 U3-1).
- This would change if one shared parser module ran on both sides.

## Prior requests

- 2026-11-17 (osionos main session): profile page spec rev 1, units U3 and U4.
