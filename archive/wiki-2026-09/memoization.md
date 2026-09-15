# Memoization

**One line:** cache the result of a pure computation against its inputs, so the
second call with the same inputs returns the stored answer instead of recomputing it.

Memoization is **space traded for time**. You keep a small table — *inputs → result* —
and consult it before doing the work. A *hit* skips the work; a *miss* does the work
once and records it. That is the whole idea. Everything below is consequences of it.

> This page teaches the concept by **antithesis**: each section shows the *same
> function, same context*, written **without** memoization and then **with** it, so the
> only difference is the cache. Every "with" snippet is grounded in real code in this
> repo (links inline).

---

## The mental model

```text
                 ┌─────────────────────────────────────────────┐
   call f(args)  │  key = keyOf(args)                           │
  ───────────────▶  cache has key?                              │
                 │     ├─ yes ──▶ return cache[key]   (HIT  — no work)
                 │     └─ no  ──▶ result = f(args)              │
                 │                cache[key] = result   (MISS — work once)
                 │                return result                 │
                 └─────────────────────────────────────────────┘
```

Three things have to be true for this to be **correct**, not just fast:

1. **`f` is pure** — same inputs always produce the same output, no side effects. If
   `f` depends on the clock, a database, or mutable global state, a cached answer can be
   *stale* or *wrong*. (We handle the "must expire" case in [Server-side](#4-server-side--an-expiring-keyed-cache-rust).)
   Pure *output* isn't the whole story: memoization also changes **how often side effects
   run** — a miss runs `f` once, every hit skips it. A caller that relies on a side effect
   firing on *every* call breaks the moment you memoize. Idempotency (safe to apply more
   than once) is the companion property to lean on.
2. **The key captures every input** — if two calls that should differ map to the same
   key, you serve one the other's answer. A *missing* dependency is the classic memo bug.
3. **Stable keys for stable inputs** — if "the same" input produces a *different* key
   each time, every call is a miss and the cache only adds overhead. (This is the
   referential-stability trap in [§3](#3-referential-stability--usecallback--reactmemo).)

---

## The antithesis, four ways

### 1. The textbook case — Fibonacci (exponential → linear)

Same function — the nth Fibonacci number by its own recurrence. The naive version
re-derives the *same* sub-results an exponential number of times.

**Without memoization** — `fib(n)` recomputes `fib(n-2)` inside both `fib(n-1)` and
`fib(n-2)`, so the call tree branches every level:

```ts
function fib(n: number): number {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
// fib(40) makes 331,160,281 calls (= 2·fib(41)−1). fib(50) takes on the order of
// ~40s in a warm V8 (~40.7 billion calls, hardware-dependent). Each fib(k) is
// recomputed over and over — fib(2) alone runs fib(39) ≈ 63 million times.
// Time:  O(φⁿ) ≈ O(1.618ⁿ)  (loosely quoted as O(2ⁿ))      Space: O(n) stack
```

**With memoization** — the first time we compute `fib(k)` we store it; every later
request for the same `k` is a table lookup:

```ts
function makeFib(): (n: number) => number {
  const cache = new Map<number, number>();      // key (n) → result
  function fib(n: number): number {
    if (n < 2) return n;
    const hit = cache.get(n);
    if (hit !== undefined) return hit;           // HIT — no work
    const result = fib(n - 1) + fib(n - 2);      // MISS — compute once
    cache.set(n, result);
    return result;
  }
  return fib;
}
const fib = makeFib();
// fib(40) now makes exactly 79 calls instead of 331 million (2n−1 invocations).
// Time:  O(n)        Space: O(n) cache + O(n) stack
```

**What changed:** one `Map` and two lines. The asymptotic class collapsed from
**exponential to linear** — memoized `fib(50)` makes 99 calls instead of ~40.7 billion,
tens of seconds down to imperceptible. This is memoization at its most dramatic: the
redundant work was *the entire cost*.

---

### 2. Pure derivation in React — `useMemo`

Same function as the repo's real
[useConversationFilter.ts](../apps/osionos/app/src/widgets/messages-view/model/useConversationFilter.ts):
a pure filter over a conversation list. The pure part never changes between the two
versions — only whether we memoize the call.

```ts
// The pure computation — identical in both versions:
export function filterConversations(
  conversations: Conversation[],
  scope: ConversationScope,
  query: string,
): Conversation[] {
  const needle = query.trim().toLowerCase();
  return conversations.filter((c) => matchesScope(c, scope) && matchesQuery(c, needle));
}
```

**Without memoization** — call it straight in the render body:

```tsx
function ConversationPanel({ conversations, scope, query }: Props) {
  // Recomputed on EVERY render — even a render caused by something unrelated
  // (a parent re-render, an unrelated state change). Worse: `filtered` is a
  // BRAND-NEW array each render, so its reference changes every time.
  const filtered = filterConversations(conversations, scope, query);

  useEffect(() => { markAllSeen(filtered); }, [filtered]); // ← fires every render
  return <ConversationList items={filtered} />;            // ← memo'd child re-renders anyway
}
```

The cost is two-fold: the filter re-runs needlessly, **and** the fresh array identity
ripples downstream — the `useEffect` fires every render and a `React.memo`'d
`ConversationList` can never skip, because its `items` prop is "new" each time. (Stable
`items` is *necessary but not sufficient*: `React.memo` skips only when **every** prop is
reference-equal, so a freshly-minted handler prop would defeat it too — that's what §3
fixes with `useCallback`.)

**With memoization** — the actual repo hook wraps the same call in `useMemo`:

```ts
export function useConversationFilter(
  conversations: Conversation[],
  scope: ConversationScope,
  query: string,
): Conversation[] {
  return useMemo(
    () => filterConversations(conversations, scope, query),
    [conversations, scope, query],   // ← the key: recompute only when these change
  );
}
```

```tsx
function ConversationPanel({ conversations, scope, query }: Props) {
  const filtered = useConversationFilter(conversations, scope, query);
  useEffect(() => { markAllSeen(filtered); }, [filtered]); // ← fires only when the filter result changes
  return <ConversationList items={filtered} />;            // ← memo'd child now skips unchanged renders
}
```

**What changed:** the dependency array `[conversations, scope, query]` *is* the cache
key. Same inputs → React returns the **same array reference** → the recompute is skipped
**and** the stable identity stops the downstream re-render/effect cascade. The same shape
appears at [CalendarGrid.tsx:97](../apps/calendar/src/components/CalendarGrid.tsx#L97):
`const sortedEvents = useMemo(() => [...events].sort(eventSort), [events]);`.

> **Note — the two payoffs are different.** Skipping the *recompute* matters only when
> the computation is expensive. Skipping the *re-render cascade* (stable reference)
> matters even for cheap computations, because the cost is paid by children. Most React
> `useMemo` is bought for the second reason, not the first.

---

### 3. Referential stability — `useCallback` / `React.memo`

This is the React-specific face of rule 3 ("stable keys for stable inputs"). The
"computation" is *constructing an object* (a function, a list of blocks). If you mint a
fresh reference for value-identical data, every reference-comparing consumer treats it as
changed. The repo applies this pattern in
[reconcileBlocks.ts](../apps/osionos/app/src/features/raw-mode/model/reconcileBlocks.ts)
and [RawPreviewPane.tsx](../apps/osionos/app/src/features/raw-mode/ui/RawPreviewPane.tsx) —
the reconcile + `React.memo` half below is verbatim from those files; the `useCallback`
handler is an illustrative companion (the real `ReadOnlyBlock` takes only `block`/`index`).

**Without memoization** — a child guarded by `React.memo`, fed a freshly-built prop each render:

```tsx
// Real one supplies a custom comparator whose first check is `prev.block === next.block`,
// so block reference-identity is exactly what drives the skip.
const ReadOnlyBlock = React.memo(ReadOnlyBlockImpl); // skips re-render if props are ===

function PreviewPane({ source }: { source: string }) {
  // parseMarkdownToBlocks mints a fresh crypto.randomUUID() per block every call,
  // so two parses of the SAME source produce value-identical blocks with DIFFERENT
  // object references. React.memo compares by reference → every block looks "new" →
  // a single keystroke re-renders the WHOLE preview tree.
  const blocks = parseMarkdownToBlocks(source);

  const onPick = (id: string) => select(id);  // ← also fresh every render
  return blocks.map((b) => <ReadOnlyBlock key={b.id} block={b} onPick={onPick} />);
}
```

**With memoization** — reconcile against the previous parse to *reuse references* for
unchanged blocks, and `useCallback` to keep the handler identity stable:

```tsx
function PreviewPane({ source }: { source: string }) {
  const previousBlocksRef = useRef<Block[]>([]);
  const blocks = useMemo(() => {
    // reconcileBlocks reuses the PREVIOUS object reference wherever a block is
    // structurally unchanged → unchanged blocks keep a stable identity →
    // React.memo short-circuits them → only the block being edited re-renders.
    const reconciled = reconcileBlocks(parseMarkdownToBlocks(source), previousBlocksRef.current);
    previousBlocksRef.current = reconciled;
    return reconciled;
  }, [source]);

  const onPick = useCallback((id: string) => select(id), [select]); // stable while `select` is
  return blocks.map((b) => <ReadOnlyBlock key={b.id} block={b} onPick={onPick} />);
}
```

**What changed:** nothing about *what* is computed — both parse the same markdown. The
"with" version memoizes **identity**: stable block references and a stable callback let
`React.memo` do its job, so a per-keystroke edit re-renders one block instead of the
whole tree. (`RawPreviewPane` itself is also wrapped in `React.memo` so the parent's
per-keystroke render skips the pane entirely until the debounced `source` changes — the
same trick one level up.) Reach for `useCallback`/`React.memo` **only** when a memoized
or expensive child actually consumes the value; otherwise the wrapper is pure overhead
(see [pitfalls](#when-not-to-memoize)).

---

### 4. Server-side — an expiring, keyed cache (Rust)

Memoization is not a frontend idea. The data plane caches the resolution of a database
*mount* to a concrete DSN, because resolving means **decrypting a credential** — real
work you don't want to repeat per query. Grounded in
[resolver.rs](../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/resolver.rs#L36).

**Without memoization** — decrypt and assemble the DSN on every resolve:

```rust
fn resolve(&self, mount: &DatabaseMount) -> DataPlaneResult<String> {
    // Decrypts the credential and builds the DSN on EVERY call — even though the
    // same mount yields the same DSN until its credential is rotated.
    build_dsn(mount)
}
```

**With memoization** — a process-wide cache keyed by `pool_key`, with safety properties a
pure memo doesn't need (illustrative shape — the real `resolve_dsn` is `async` and
`CredentialCache::put` takes `&str`):

```rust
struct CredentialCache {
    ttl: Duration,                                  // 0 = disabled (never cache)
    entries: Mutex<HashMap<String, (String, Instant)>>, // pool_key → (dsn, stored_at)
}

fn resolve(&self, mount: &DatabaseMount) -> DataPlaneResult<String> {
    let key = mount.pool_key();                     // embeds credential_ref.version
    if let Some(dsn) = self.cache.get(&key) {       // HIT (and still within TTL)
        return Ok(dsn);
    }
    let dsn = build_dsn(mount)?;                     // MISS — decrypt once
    self.cache.put(&key, &dsn);                      // put takes &str (see note above)
    Ok(dsn)
}
```

**What changed, and why server caches are harder:** a pure memo (Fibonacci) can keep a
value forever. A *DSN* can go stale, so this cache adds the two things rules 1–3 don't
cover on their own:

- **Expiry (TTL).** Entries carry a timestamp; a hit past `ttl` is treated as a miss.
  This bounds how stale a cached answer can be when the source of truth changes underneath.
- **Invalidation by key design.** The key embeds `credential_ref.version`, so rotating a
  credential **bumps the version → keys a brand-new entry**. The old key is never
  *consulted* again, so there's no correctness risk — *cache invalidation by making the
  key change* is the cleanest kind. Reclaiming its *memory* is separate: that still needs
  the TTL to expire it or an explicit `evict`/`drain_pool_key` on rotation (the resolver
  provides both) — an unreachable-but-undropped entry is still the unbounded-`Map` leak
  this page warns about in [pitfalls](#when-not-to-memoize).
- **Synchronization.** A *shared* cache needs a lock — that's the `Mutex` — and ideally
  single-flight, so two threads that miss the same key don't both run the expensive
  decrypt (the dogpile / thundering-herd problem). The JS examples sidestep all of this
  only because they're single-threaded.

This is the general lesson: **a cache over impure/aging data is only as correct as its
expiry and invalidation.** "There are only two hard things in computer science: cache
invalidation and naming things" is about exactly this section, not the Fibonacci one.

---

## The flavours, side by side

| Flavour | What's cached | Keyed by | Wins you | In this repo |
|---|---|---|---|---|
| **Function memo** | a pure function's return | its arguments | skips recomputation (can change Big-O) | `makeFib` pattern; any pure derivation |
| **Render memo** (`useMemo`) | a derived value per render | the dependency array | skips recompute **+** stable reference | [useConversationFilter.ts](../apps/osionos/app/src/widgets/messages-view/model/useConversationFilter.ts), [CalendarGrid.tsx:96-97](../apps/calendar/src/components/CalendarGrid.tsx#L96-L97) |
| **Referential memo** (`useCallback`, `React.memo`, reconcile) | object/function *identity* | deps / structural equality | lets memoized children skip re-render | [RawPreviewPane.tsx](../apps/osionos/app/src/features/raw-mode/ui/RawPreviewPane.tsx), [reconcileBlocks.ts](../apps/osionos/app/src/features/raw-mode/model/reconcileBlocks.ts) |
| **Server cache** (TTL) | an expensive resolution | a content/version key | skips repeated I/O/crypto | [resolver.rs](../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/resolver.rs#L36) |

All four are the *same* idea — *inputs → result* table consulted before doing work. They
differ only in **what counts as an input** and **whether the answer can expire**.

---

## When NOT to memoize

Memoization is not free, and applied reflexively it makes code slower and buggier.

- **The computation is already cheap.** Memoizing `a + b` or a 5-element `.map()` adds a
  cache, a comparison, and a closure to save work that was never expensive. The wrapper
  costs more than the call. (In React, the exception is when you need the *stable
  reference*, not the saved compute — see §2's note.)
- **The function is impure.** Caching a value that depends on the clock, randomness, the
  network, or mutable globals serves stale or wrong answers. If you must, you need TTL +
  invalidation ([§4](#4-server-side--an-expiring-keyed-cache-rust)) — and now you own a
  correctness problem, not just a perf optimization.
- **The key is unstable.** A `useMemo`/`useCallback` whose dependency is rebuilt every
  render (an inline object/array/function in the deps) **never hits** — it's pure
  overhead plus a false sense of optimization. Fix the key's stability first.
- **The cache grows unbounded.** A `Map` keyed by user input is a memory leak (and a DoS
  vector) unless it's bounded — cap the size, use an LRU, or set a TTL. When the key is an
  *object you don't own*, a `WeakMap` lets the entry die with the key (GC-collected, no
  explicit eviction). The textbook `fib` cache is safe only because its keyspace is tiny
  and trusted.
- **You haven't measured.** Memoization is an optimization; optimizations need a
  before/after. Adding `useMemo` everywhere "to be safe" is cargo-culting — it clutters
  the code, fights the React Compiler / future tooling, and usually saves nothing. Profile,
  find the hot path, memoize *that*.

---

## Decision checklist

Before adding a memo, answer all five:

1. **Is the function pure?** If not, can it tolerate a TTL, or is it disqualified?
2. **Is recomputing actually expensive,** or do I want the *stable reference* instead?
3. **Does my key capture every input** — and *only* inputs that should invalidate?
4. **Is the key stable** for inputs that are "the same"? (No fresh objects in deps.)
5. **Is the cache bounded** (size / TTL / `WeakMap`), or is the keyspace small and trusted?

If you can't answer 1, 3, 4, and 5 cleanly, the memo is a latent bug, not a speedup.

---

## See also

- [useConversationFilter.ts](../apps/osionos/app/src/widgets/messages-view/model/useConversationFilter.ts) — the pure-derivation + `useMemo` pattern, verbatim.
- [reconcileBlocks.ts](../apps/osionos/app/src/features/raw-mode/model/reconcileBlocks.ts) / [RawPreviewPane.tsx](../apps/osionos/app/src/features/raw-mode/ui/RawPreviewPane.tsx) — referential stability and `React.memo` in practice.
- [resolver.rs](../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/resolver.rs) — a real TTL- and version-keyed server cache (the invalidation half of the story).
- [.claude/rules/dsa-and-memory.md](../.claude/rules/dsa-and-memory.md) — when speed beats simplicity, and pooling high-churn allocations (the allocation cousin of caching).
