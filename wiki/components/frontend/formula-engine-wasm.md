# Formula-engine WASM bridge — lazy init + graceful degradation (osionos)

> **In one sentence.** The WASM bridge safely loads a Rust formula engine into JavaScript on demand as a lazy singleton, deduplicates concurrent init calls with a single promise, and degrades gracefully to showing blank formula cells if WASM is missing or disabled.

## What it is & why it exists

The formula-engine bridge is a TypeScript module that sits between the Notion-like database UI and a compiled Rust formula evaluator (as [WebAssembly](glossary.md#wasm)). It handles the entire lifecycle: optional loading, safe instantiation, and calling. The architectural gem is how it fails. Rather than crashing if the WASM binary is missing or the browser doesn't support WASM, every exported function (evalFormula, compileFormula, batchEvaluate, validateFormula) simply returns a safe default value—most of the time FORMULA_ENGINE_UNAVAILABLE, which signals 'this feature is disabled' without breaking the app. Formula columns just show blank.

Internally it uses three module-level state flags (wasmEngine, initPromise, initFailed) to track whether the engine is loaded, currently initializing, or has permanently failed. This is not an over-engineered state machine; it is a pragmatic guard pattern. The [promise deduplication](glossary.md#promise-deduplication) (initPromise ??=) is the most elegant piece: if two callers invoke initFormulaEngine concurrently, both await the same Promise instead of each spawning their own WebAssembly.instantiate call.

## How it works

- On first call to initFormulaEngine(), check if the engine is already loaded (wasmEngine !== null) or initialization has permanently failed (initFailed === true); if either, return immediately.
- If neither, and WASM is not disabled via compile-time flag, begin initialization: create an async function that imports the compiled WASM module from ./pkg/formula_engine.js and calls its default export to instantiate WebAssembly.
- Use the [nullish coalescing assignment](glossary.md#nullish-coalescing-assignment) (initPromise ??=) to ensure only one Promise is created; subsequent concurrent calls wait on the same Promise instead of spawning new instantiations.
- On success, store the WASM module in the [singleton](glossary.md#singleton) wasmEngine variable so future calls see it immediately and return true.
- On any error (missing binary, unsupported browser, JSON parse failure, etc.), log a warning, set initFailed = true, and return false; all subsequent calls will then return false without retrying.
- Every public function (evalFormula, compileFormula, batchEvaluate, etc.) checks if (!wasmEngine) first; if the engine is unavailable, return a safe default: FORMULA_ENGINE_UNAVAILABLE string or an empty array/object depending on the function's contract.
- Wrap all WASM calls in [try/catch](glossary.md#try-catch-guard) so runtime errors (e.g., corrupted handles, type mismatches) never propagate; catch errors also return the safe default.
- Cache compiled formula handles in formulaHandleCache (Map<formula string, handle number>) so the same formula is never compiled twice; compileFormula checks the cache on entry, and batchEvaluate reuses cached handles.

## The code that does it

**What to look at:** Lazy singleton initialization with promise deduplication (??=) ensures concurrent callers share one instantiation, and graceful failure sets initFailed to signal permanent unavailability.

```ts
// apps/osionos/app/src/shared/notion-database-sys/src/lib/engine/bridge.ts:62-84
export async function initFormulaEngine(): Promise<boolean> {
  if (wasmEngine) return true;
  if (initFailed) return false;
  if (isFormulaEngineDisabled()) {
    initFailed = true;
    return false;
  }

  initPromise ??= (async () => {
    try {
      const mod = await import('./pkg/formula_engine.js');
      await mod.default();                   // WebAssembly.instantiate
      wasmEngine = mod as unknown as WasmEngine;
      return true;
    } catch (err) {
      console.warn('[formula-engine] WASM init failed, formulas disabled:', err);
      initFailed = true;
      return false;
    }
  })();

  return initPromise;
}
```

**What to look at:** Three-state guard system (wasmEngine, initPromise, initFailed) and FORMULA_ENGINE_UNAVAILABLE constant enable safe degradation: missing WASM silently disables formulas instead of crashing.

```ts
// apps/osionos/app/src/shared/notion-database-sys/src/lib/engine/bridge.ts:47-92
/* ── Singleton state ────────────────────────────────────────────────────── */

let wasmEngine: WasmEngine | null = null;
let initPromise: Promise<boolean> | null = null;
let initFailed = false;

const formulaHandleCache = new Map<string, number>();

declare const __OBJECT_DATABASE_DISABLE_WASM__: boolean | undefined;

/** Stable placeholder returned when the optional WASM formula engine is unavailable. */
export const FORMULA_ENGINE_UNAVAILABLE = '#ENGINE_UNAVAILABLE';

/* ── Initialization (lazy, singleton, deduped) ──────────────────────────── */

export async function initFormulaEngine(): Promise<boolean> {
  if (wasmEngine) return true;
  if (initFailed) return false;
  if (isFormulaEngineDisabled()) {
    initFailed = true;
    return false;
  }

  initPromise ??= (async () => {
    try {
      const mod = await import('./pkg/formula_engine.js');
      await mod.default();                   // WebAssembly.instantiate
      wasmEngine = mod as unknown as WasmEngine;
      return true;
    } catch (err) {
      console.warn('[formula-engine] WASM init failed, formulas disabled:', err);
      initFailed = true;
      return false;
    }
  })();

  return initPromise;
}

function isFormulaEngineDisabled(): boolean {
  return __OBJECT_DATABASE_DISABLE_WASM__ !== undefined && __OBJECT_DATABASE_DISABLE_WASM__;
}

export function isWasmReady(): boolean {
  return wasmEngine !== null;
}
```

**What to look at:** Every exported function checks if (!wasmEngine) first, wraps WASM calls in try/catch, and returns FORMULA_ENGINE_UNAVAILABLE on any failure so the app never crashes.

```ts
// apps/osionos/app/src/shared/notion-database-sys/src/lib/engine/bridge.ts:116-126
export function evalFormula(formula: string, props: PropertyMap): unknown {
  if (!wasmEngine) return FORMULA_ENGINE_UNAVAILABLE;
  try {
    const propsJson = serializeProps(props);
    const resultJson = wasmEngine.eval_formula(formula, propsJson);
    const result: EvalResult = JSON.parse(resultJson);
    return result.ok ? fromFormulaValue(result.value) : FORMULA_ENGINE_UNAVAILABLE;
  } catch {
    return FORMULA_ENGINE_UNAVAILABLE;
  }
}
```

## Where it sits in the app

The bridge sits inside the object-database layer (notion-database-sys, a vendored Rust+TypeScript submodule). Callers are database view adapters and computed-property slices that need to evaluate formulas on rows: they import evalFormula or batchEvaluate, pass a formula string and property values, and receive the result (or FORMULA_ENGINE_UNAVAILABLE if WASM is absent). The bridge never reaches the network; it only calls the local WASM engine or fails gracefully. The osionos frontend never knows whether formulas are available; it just renders blank cells if they are not.

## Remember this

> When WASM is unavailable, return a safe default value, not an error or crash.

---
**See also:** [useAuth-client.md](useAuth-client.md) · [mail-bridge-client.md](mail-bridge-client.md) · [useGraphEngine.md](useGraphEngine.md) · [mail-cache.md](mail-cache.md) · [Glossary](glossary.md)
