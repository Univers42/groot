# Glossary

Shared vocabulary for the frontend component wiki — [useAuth-client.md](useAuth-client.md), [mail-bridge-client.md](mail-bridge-client.md), [useGraphEngine.md](useGraphEngine.md), [mail-cache.md](mail-cache.md), and [formula-engine-wasm.md](formula-engine-wasm.md). Entries are sorted alphabetically.

### Access token
**Plain English.** A credential (often a JWT) issued after a successful login that the client sends in `Authorization` headers to prove its identity to an API.
**In the frontend.** `useAuth-client` methods return `accessToken` and `expiresIn`; `osionosSession()` accepts an access token to start a downstream workspace session.

### Auth gateway
**Plain English.** A backend service that handles authentication logic — login, register, token refresh, MFA — on behalf of the frontend.
**In the frontend.** `useAuth-client` POSTs to the auth gateway's `/login`, `/register`, `/refresh`, `/logout`, and `/mfa/*` endpoints.

### BFF
**Plain English.** A Backend-for-Frontend: a dedicated server between the UI and the core APIs that exposes only the exact data shape and operations the UI needs.
**In the frontend.** `mail-bridge-client` talks to the BFF via `/session`, `/auth`, `/messages`, and `/actions`; the BFF abstracts multiple email providers behind one contract.

### Cleanup function
**Plain English.** The function returned from `useEffect`; React runs it before the effect runs again or when the component unmounts, to free resources.
**In the frontend.** In `useGraphEngine`, the mount effect's cleanup disconnects both observers, destroys the engine, and nulls `engineRef` to prevent leaks.

### Composite key
**Plain English.** A single normalized string built from several lookup dimensions (here endpoint + account) to guarantee uniqueness.
**In the frontend.** `mail-cache`'s `cacheKey` merges a normalized endpoint and a lowercased account behind a constant prefix, so each provider/account pair gets its own stored data.

### CSRF
**Plain English.** Cross-Site Request Forgery — an attack where a malicious site rides a victim's existing session to make state-changing requests; defended with same-origin checks plus a per-session token the server verifies.
**In the frontend.** `useAuth-client` carries same-origin credentials and a turnstile/CSRF token on unsafe requests so the gateway can reject forged cross-origin writes.

### Dependency array
**Plain English.** The optional second argument to `useEffect`; it lists the values whose change re-runs the effect, and an empty array means run once.
**In the frontend.** In `useGraphEngine`, the mount effect uses an empty array to run once, while each sync effect watches one prop so it re-runs only when that prop changes.

### Device pixel ratio
**Plain English.** The ratio of physical device pixels to CSS pixels (e.g. 2.0 on a Retina display), used to render crisp graphics on high-DPI displays.
**In the frontend.** `useGraphEngine` reads `window.devicePixelRatio` and passes it to `engine.setSize()` so canvas buffers render at native device resolution.

### encodeURIComponent
**Plain English.** A browser function that percent-encodes characters unsafe in a URL path, so `@` becomes `%40` and `/` becomes `%2F`.
**In the frontend.** `mail-bridge-client` wraps `messageId` in `encodeURIComponent` in `applyBridgeAction` and `loadBridgeMessage`, since provider IDs may contain slashes or other reserved characters.

### EngineCallbacks
**Plain English.** An object of interaction handlers — `onSelect`, `onHover`, `onExpand` — that an engine fires when the user interacts with graph nodes.
**In the frontend.** `useGraphEngine` receives them, wraps each to call `cbRef.current` (avoiding stale closures), and forwards them to the `GraphEngine` constructor.

### Exponential backoff
**Plain English.** A retry strategy that grows the delay between attempts — 400 ms, then 800 ms, then 1600 ms — to avoid hammering a server that is already rate-limiting.
**In the frontend.** `useAuth-client`'s `fetchWithBackoff` computes `baseDelay = 400 * 2^attempt` with `maxRetries` defaulting to 3.

### Graceful degradation
**Plain English.** Letting a system keep working with reduced capability when a subsystem fails, instead of crashing outright.
**In the frontend.** `mail-cache` returns `null` or skips the write on storage errors so the UI renders without cache; `formula-engine-wasm` returns a sentinel or safe default when WASM is unavailable, showing blank formula cells rather than crashing.

### GraphEngine
**Plain English.** A framework-agnostic imperative facade that manages Canvas2D rendering, Web Worker physics layout, and theme resolution for a force-directed graph.
**In the frontend.** `useGraphEngine` instantiates one `GraphEngine` per hook, stores it in `engineRef`, and drives it via `setModel`, `setControls`, `setTheme`, and `setSize`.

### HTTP 429
**Plain English.** The "Too Many Requests" status code a server sends when a client exceeds its rate limit.
**In the frontend.** `useAuth-client`'s `fetchWithBackoff` detects 429 responses and retries with exponential backoff plus jitter.

### localStorage
**Plain English.** A browser key-value store that persists across sessions (roughly 5–10 MB per origin) until explicitly cleared.
**In the frontend.** `mail-cache` routes every read and write through `globalThis.localStorage` with availability checks, as its primary persistence layer.

### Message compaction
**Plain English.** Shrinking an object by truncating or dropping fields so it fits the storage quota while keeping enough for preview and search.
**In the frontend.** `mail-cache`'s `compactMessage` strips `bodyHtml` for Gmail, prefers the snippet over the full body, and sets `bodyLoaded=false` to save space.

### MFA
**Plain English.** Multi-Factor Authentication — requiring more than one proof of identity, typically a password plus a second factor like a TOTP code or a security key.
**In the frontend.** `useAuth-client` exposes `beginMfaTotpEnrollment`, `verifyMfaTotp`, and `beginWebAuthn` for the second-factor flows.

### MutationObserver
**Plain English.** A browser API that watches the DOM for changes — attribute edits, content insertion, style changes — and fires a callback when they happen.
**In the frontend.** `useGraphEngine` watches `document.documentElement` for `data-theme`/class/style changes and calls `engine.setTheme()` to react to theme switches.

### Nullish coalescing assignment
**Plain English.** The `??=` operator assigns a value only when the variable is currently `null` or `undefined`, leaving any existing value untouched.
**In the frontend.** `formula-engine-wasm` uses `initPromise ??= (async () => {...})` so initialization starts exactly once; later callers see a non-null promise and skip the assignment.

### OAuth
**Plain English.** An authorization standard in which a user logs in to a provider in a separate browser context and grants the app scoped access without sharing the password.
**In the frontend.** `mail-bridge-client`'s `openBridgeAuth` opens the provider login via `globalThis.open()` with `noopener,noreferrer` so the popup cannot reach the parent window's globals.

### osionos bridge
**Plain English.** The downstream service the user reaches after authenticating; its endpoint creates a session and returns a redirect URL.
**In the frontend.** `useAuth-client`'s `osionosSession()` takes an access token and returns `redirectUrl` and `workspaceId`, bridging into the osionos workspace.

### Pagination token
**Plain English.** An opaque string a server returns so the client can resume a partial result set, avoiding offset-based queries over large datasets.
**In the frontend.** `mail-bridge-client`'s `syncBridgeMessages` sends `pageToken` and receives `nextPageToken`; `mail-cache` stores `nextPageToken` so incremental sync resumes at the exact cursor on reconnect.

### prefers-reduced-motion
**Plain English.** A CSS media query reflecting the user's system accessibility setting to minimize animation and motion.
**In the frontend.** `useGraphEngine` checks it via `matchMedia()` at engine init and passes the result to `GraphEngine` so physics and animation respect the user's motion preference.

### Promise deduplication
**Plain English.** Reusing one in-flight promise across concurrent callers so the same async work doesn't start twice when multiple call sites request the same resource at once.
**In the frontend.** `formula-engine-wasm`'s `initPromise ??=` pattern makes concurrent `initFormulaEngine` callers await one shared promise instead of two separate WASM instantiations.

### QuotaExceededError
**Plain English.** The exception thrown when `localStorage` is full and cannot store more data.
**In the frontend.** `mail-cache` catches it in `saveMailboxCache`'s try/catch and immediately removes the partial write to avoid leaving corrupt data behind.

### Random jitter
**Plain English.** A small random amount added to retry delays so many clients don't all retry at the same instant (the "thundering herd").
**In the frontend.** `useAuth-client`'s `randomJitter(150)` adds 0–150 ms to each backoff delay, seeded with `crypto.getRandomValues` for cryptographic-quality randomness.

### React hook
**Plain English.** A JavaScript function that lets a React functional component use state, side effects, and other features once exclusive to class components.
**In the frontend.** `useAuth-client` and `useGraphEngine` are both custom React hooks that encapsulate logic and return a stable object of values/methods.

### ref
**Plain English.** A React reference object holding a mutable `current` value that survives re-renders without triggering them, used for DOM nodes or long-lived objects.
**In the frontend.** `useGraphEngine` holds `containerRef`, `bgRef`, `fgRef`, `engineRef`, and `cbRef` so React never re-mounts the canvases or recreates the engine on prop changes.

### ResizeObserver
**Plain English.** A browser API that fires a callback whenever a watched element's size changes, without listening to window-level resize events.
**In the frontend.** `useGraphEngine` observes the container element and, on resize, calls `engine.setSize()` with the new dimensions and device pixel ratio.

### Retry-After
**Plain English.** An HTTP response header telling the client how many seconds to wait before retrying, sent with 429 or 503 responses.
**In the frontend.** `useAuth-client`'s `fetchWithBackoff` honors the `Retry-After` header when present, using it instead of the calculated exponential delay.

### RFC 5322
**Plain English.** The Internet standard defining email message header format, including valid email address syntax.
**In the frontend.** `useAuth-client`'s `RFC_5322_EMAIL_REGEX` validates the local and domain parts of an address per this standard, supporting plus-addressing, dots, and quoted strings.

### Same-origin
**Plain English.** Requests sent to the same protocol, host, and port as the current page — the case in which the browser will automatically attach cookies.
**In the frontend.** `useAuth-client` uses `credentials:'include'` so session cookies ride along with same-origin requests to the auth gateway; this plus CSRF checks blocks cross-site forgery.

### Singleton
**Plain English.** A design pattern that guarantees exactly one instance of a resource exists for the whole app, reached through a single access point.
**In the frontend.** `formula-engine-wasm` keeps `wasmEngine` as a module-level variable holding the one and only WASM engine instance; every function reads and writes it, never creating duplicates.

### Stale closure
**Plain English.** A function that captures outdated values because it was created in an earlier render and never refreshed when its dependencies changed.
**In the frontend.** `useGraphEngine` avoids it by assigning `cbRef.current = args.callbacks` on every render and reading `cbRef.current` inside engine callbacks, so the engine always invokes the latest handler.

### TOTP
**Plain English.** Time-based One-Time Password — an MFA method where the user's device derives a 6-digit code that rotates every 30 seconds from a shared secret.
**In the frontend.** `useAuth-client`'s `beginMfaTotpEnrollment` starts enrollment and `verifyMfaTotp` submits the 6-digit code to the gateway for validation.

### Try catch guard
**Plain English.** Wrapping fallible code in a `try` block and handling exceptions in a `catch` block so unhandled errors never propagate.
**In the frontend.** `formula-engine-wasm` wraps every exported function (`evalFormula`, `batchEvaluate`, `validateFormula`) so WASM call errors and JSON parse errors return safe defaults instead of throwing.

### URLSearchParams
**Plain English.** A Web API for building percent-encoded query strings that escapes special characters and joins key-value pairs automatically.
**In the frontend.** `mail-bridge-client`'s `syncBridgeMessages` builds `limit`, `pageToken`, `paged`, and `includeBodies` as query parameters with it, avoiding manual string concatenation.

### Version gate
**Plain English.** A check that discards stored data when its schema version doesn't match the version the current code expects.
**In the frontend.** `mail-cache`'s `readCache` compares `parsed.version` against the `CACHE_VERSION` constant (2) and returns `null` on mismatch, forcing a fresh sync.

### WASM
**Plain English.** WebAssembly — a binary instruction format for a stack-based virtual machine that runs sandboxed in the browser at near-native speed, letting languages like Rust execute in JavaScript environments.
**In the frontend.** `formula-engine-wasm` is compiled from Rust to WASM, then dynamically imported and instantiated through a bridge to evaluate database formulas.

### Web Worker
**Plain English.** A background JavaScript thread that runs separately from the main thread, used to keep heavy work from blocking rendering and input.
**In the frontend.** `useGraphEngine`'s engine runs physics layout in a Web Worker (via its `LayoutController`) so the simulation never stalls the render thread.

### WebAuthn
**Plain English.** A W3C standard for passwordless authentication using biometrics or hardware security keys — more secure and friendlier than passwords.
**In the frontend.** `useAuth-client`'s `beginWebAuthn` calls the gateway's `/mfa/webauthn/options` endpoint to fetch options for registering or authenticating with a security key.
