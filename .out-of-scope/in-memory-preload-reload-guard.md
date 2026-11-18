# An in-memory fallback for the stale-chunk reload guard is out of scope

- Decided: 2026-11-18 · by devil (ADR 0061 PR2)
- Holds while: the guard protects against a loop of `location.reload()` calls.

## The concept

When `sessionStorage` is missing, the stale-chunk reload guard in osionos `src/app/main.tsx:51-53` would keep its "last reloaded at" time in a module variable instead, so the guard would no longer read 0 every time.

## Why not

- The loop being guarded crosses documents: reload, boot, the same chunk missing, reload again. A reload discards every module variable, so each new document starts at 0 and reloads once more. The fallback stops nothing.
- What replaces it (ADR 0061 PR2): the page reloads only when the guard write reads back from storage. With no durable storage it does not reload at all, and the lazy feature fails visibly.
- The answer changes only if some cross-document store is available exactly when `sessionStorage` is not. Nobody has shown such a store.

## Prior requests

- 2026-11-18 (coordinator, R-BR5 question 2): "fix in this unit (in-memory fallback) or separate unit?"

## Reopen when

A measurement shows a real browser setting in which `sessionStorage` is null or throws while another cross-document store still persists across `location.reload()`.
