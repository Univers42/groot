# Nonce + `'strict-dynamic'` for the osionos app CSP is out of scope for phase 1

- Decided: 2026-11-22 · by devil (ADR 0076, RULING-314 §8)
- Holds while: the inline scripts are static and the U1 closure holds

## The concept

Vite `html.cspNonce` plus nginx `sub_filter` stamps a per-response nonce, and `'strict-dynamic'` trusts what nonced scripts load.

## Why not

- It adds per-response templating to a static nginx image.
- A nonce mismatch (a cached `index.html`, a service-worker copy) blanks the app. That failure mode does not exist with hashes.
- Hashes are static and cover the two inline scripts.

## Reopen when

The inline scripts must change per request, or both the edge MIME rewrite on the storage routes and the other U1 closures fail.
