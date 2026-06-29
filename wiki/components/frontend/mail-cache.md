# mailCache — versioned offline cache in localStorage (mail)

> **In one sentence.** mailCache is a versioned localStorage wrapper that shields the UI from storage errors by caching compact message lists per endpoint+account, returning null instead of crashing on corruption, parse failure, or quota exhaustion.

## What it is & why it exists

mailCache is an offline-first caching layer over the browser's [localStorage](glossary.md#localstorage) API. It stores versioned message snapshots (`MailboxCache`) keyed by endpoint and account identity, enabling instant page load even with no network. When writing, it compacts messages to fit quota (stripping HTML, truncating body) and catches [QuotaExceededError](glossary.md#quotaexceedederror) to remove partial writes. When reading, it validates the schema version and wraps deserialization in a try/catch so any corruption (bad JSON, version mismatch, quota exhaustion) silently returns null instead of breaking the UI.

## How it works

- On app load, `loadMailboxCache(endpoint, account)` queries localStorage using a normalized [composite key](glossary.md#composite-key) built from both dimensions.
- `readCache()` safely deserializes JSON and compares the stored version against `CACHE_VERSION`; if versions mismatch or parsing fails, it returns null without throwing — a [version gate](glossary.md#version-gate) that guards against stale schemas.
- When the server responds with fresh messages, `saveMailboxCache()` compresses each message (via `compactMessage`) to reduce footprint through [message compaction](glossary.md#message-compaction), then writes the versioned blob to storage.
- If write hits QuotaExceededError, the catch block immediately `removeItem()` the partial write to prevent corruption of future reads.
- A secondary key (`CACHE_INDEX_KEY`) tracks the most recently synced account, so `loadLatestMailboxCache()` can restore the last viewed mailbox on restart.
- The UI always receives either a valid `MailboxCache` or null; it never sees parsing errors or storage exceptions, so [graceful degradation](glossary.md#graceful-degradation) to an offline fallback is guaranteed.

## The code that does it

**What to look at:** Availability check and composite cache key generation: endpoint+account tuple normalized with regex to handle special chars, ensuring deterministic keys across sessions.

```ts
// apps/mail/src/lib/mailCache.ts:31-37
function canUseStorage() {
  return globalThis.localStorage !== undefined;
}

function cacheKey(endpoint: string, account: string) {
  return `${CACHE_PREFIX}${endpoint.trim().replaceAll(/\W+/g, '_')}:${account.trim().toLowerCase()}`;
}
```

**What to look at:** Version-gated read with graceful null fallback: any parse error or version mismatch silently returns null so UI never crashes on corrupted storage.

```ts
// apps/mail/src/lib/mailCache.ts:49-60
function readCache(key: string): MailboxCache | null {
  if (!canUseStorage()) return null;
  const raw = globalThis.localStorage.getItem(key);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as MailboxCache;
    if (parsed.version !== CACHE_VERSION || !Array.isArray(parsed.messages)) return null;
    return parsed;
  } catch {
    return null;
  }
}
```

**What to look at:** Write path with quota resilience: compacts messages before store, wraps in try/catch, and clears the key on QuotaExceededError to prevent corruption of partial writes.

```ts
// apps/mail/src/lib/mailCache.ts:73-87
export function saveMailboxCache(cache: Omit<MailboxCache, 'version'>) {
  if (!canUseStorage() || !cache.account) return;
  const key = cacheKey(cache.endpoint, cache.account);
  const payload: MailboxCache = {
    ...cache,
    version: CACHE_VERSION,
    messages: cache.messages.map(compactMessage),
  };
  try {
    globalThis.localStorage.setItem(key, JSON.stringify(payload));
    globalThis.localStorage.setItem(CACHE_INDEX_KEY, key);
  } catch {
    globalThis.localStorage.removeItem(key);
  }
}
```

## Where it sits in the app

The user opens the app and the mail component calls `loadMailboxCache()`. If localStorage has valid data for this account, the UI renders stale messages instantly. Meanwhile, the app fetches fresh messages from the server; when they arrive, `saveMailboxCache()` updates storage for the next session. If storage is disabled, full, or corrupted, the read or write silently fails and the UI falls back to the server response or empty state—never crashes.

## Remember this

> Always return null on any storage error (unavailable, full, corrupted, wrong version) so the offline cache is transparent and the UI remains stable whether or not localStorage succeeds.

---
**See also:** [useAuth-client.md](useAuth-client.md) · [mail-bridge-client.md](mail-bridge-client.md) · [useGraphEngine.md](useGraphEngine.md) · [formula-engine-wasm.md](formula-engine-wasm.md) · [Glossary](glossary.md)
