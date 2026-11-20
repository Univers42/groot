# Encoding a canvas cell picture in backgroundColor or tint is out of scope

- Decided: 2026-11-20 · by devil ([ADR 0069](../docs/adr/0069-block-background-pictures-live-inside-block-style-render-as-a-validated-img-with-an-aa-floor-and-never-reach-p-pages.md), BG17d)
- Holds while: `LayoutBlockReadOnly` and the README projection paint cell colours as the raw `background` shorthand

## The concept

Put the cell picture in `backgroundColor` or `tint`, so that an old `unmigrate` keeps it.

## Why not

It turns a colour field into a raw `background` paint of a stored string. That is CSS injection, and on README pages it is a public beacon.

## What would change the answer

Cell colours are no longer painted through the raw `background` shorthand, and the value is grammar-checked on both sides.
