# Restricting README images to a host allowlist is out of scope

- Decided: 2026-11-17 · by devil (ADR 0058)
- Holds while: the app's own image surfaces load any host, and the stats services sit on shared-tenant domains.

## The concept

Restrict the remote images of a profile README to an allowlist of hosts, to stop a README from tracking its viewers.

## Why not

- 3 of the 10 image hosts in the reference README are `*.vercel.app`, where anyone can deploy. An allowlist that lets the README render lets a tracker in.
- Image blocks already load any host directly (`collectionMedia.ts:37`, `MediaBlockPreview.tsx:160-167`), so the allowlist would cover one surface of several.
- This would change if the app's own image surfaces stopped loading arbitrary hosts and the stats services moved off shared-tenant domains. The real fix is the image proxy, as its own unit.

## Prior requests

- 2026-11-17 (osionos main session): profile page spec rev 1, units U3 and U4.
