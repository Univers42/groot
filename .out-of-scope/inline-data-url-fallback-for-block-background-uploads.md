# Storing a failed block-background upload as a data: URL is out of scope

- Decided: 2026-11-20 · by devil ([ADR 0069](../docs/adr/0069-block-background-pictures-live-inside-block-style-render-as-a-validated-img-with-an-aa-floor-and-never-reach-p-pages.md), BG6)
- Holds while: page bodies are capped at 128 KB and the asset library lives in the 5 MiB localStorage budget

## The concept

When `uploadPageMedia` fails, keep the picture as an inline `data:` URL in the block or in the asset library.

## Why not

- One picture can exceed the 128 KB page body cap. Every later save of that page then gets a 413.
- The asset library would grow inside the 5 MiB localStorage budget, which already hits its quota.

## What would change the answer

Page bodies no longer capped at 128 KB, and the asset library no longer kept in localStorage.
