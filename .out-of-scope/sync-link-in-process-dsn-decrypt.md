# A sync worker that decrypts mount DSNs itself is out of scope

- Decided: 2026-11-24 · by devil (draft ADR `docs/adr/DRAFT-grobase-sync-link-ruling.md`, SL13)
- Holds while: the per-connection `enabled` switch is enforced only in the registry's `GetConnection`

## The concept

The webhook-dispatcher already holds the registry service token, and in the monolith the vault encryption key too. It could read and decrypt the mount rows directly, or cache DSNs, which would save one HTTP call per batch.

## Why not

- The kill switch is enforced at the registry resolve only (KS1–KS3). The inline-mount `/v1/query` does not re-check `enabled` (`data-plane-server/src/routes/query.rs:35-41`). A worker that decrypts in-process keeps writing to a connection its owner has switched off.
- The token is already on the dispatcher (`orchestrators/compose/base/storage.yml:74`), so the shortcut is one refactor away and silent.
- What would have to change: `enabled` is enforced at the data plane itself for inline mounts, with a test that a closed mount refuses an inline `/v1/query`.

## Prior requests

- 2026-11-24 (devil, sync-link ruling): pre-empted, because the dispatcher's environment makes the shortcut available.

## Reopen when

The data plane refuses inline queries for disabled mounts on its own, and a gate proves it.
