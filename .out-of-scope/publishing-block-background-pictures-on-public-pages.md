# Block background pictures on published /p/ pages are out of scope

- Decided: 2026-11-20 · by devil ([ADR 0069](../docs/adr/0069-block-background-pictures-live-inside-block-style-render-as-a-validated-img-with-an-aa-floor-and-never-reach-p-pages.md), BG13)
- Holds while: the published snapshot is read anonymously, and a block picture may name any https host

## The concept

The published snapshot keeps `style.backdrop`, so an anonymous `/p/` reader sees the picture.

## Why not

- Every anonymous reader would fetch from a host the author chose, which leaks the reader's IP to that host.
- Anyone holding the link would be exposed to signed or capability media URLs.

## What would change the answer

- A same-origin image proxy that re-serves only re-encoded pixels from our own storage, so the reader's browser fetches no third party.
- A PS47 answer for anonymous media reads.
