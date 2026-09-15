# Sync Size Clamping, Page-Size Caps, and BaaS-Mirror Timeout/Isolation — mail and calendar (Google OAuth apps)

> Both bridge servers enforce hard ceilings on every inbound sync limit and every outbound Google API page size, and isolate the BaaS mirror behind an abort timeout so that a slow or unavailable backend can never stall a user-facing fetch.

## What it is (the concept)

**Denial-of-Service (DoS) resource exhaustion** occurs when an attacker drives unbounded work on a server — by supplying a crafted parameter that forces it to fetch, process, or forward far more data than intended. Defences operate at two layers: **input bounding** (reject or clamp any parameter that would amplify downstream work) and **dependency isolation** (ensure that a slow or failed third-party call cannot propagate into an indefinite hang on the public endpoint). Both techniques limit the worst-case resource consumption of a single request to a fixed, operator-controlled ceiling.

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

In the mail and calendar bridges the threat is twofold. First, a caller that supplies a large `limit` query parameter could force the bridge to page through thousands of Gmail messages or Google Calendar events per request, exhausting memory, API quota, and CPU in a single call. Second, because both bridges optionally mirror fetched data to the BaaS gateway, a hung or unavailable gateway could cause every sync request to block indefinitely, degrading availability for all connected users.

## How mail-calendar implements it

**`apps/mail/bridge/server.mjs`** — three interlocking controls:

1. **Sync limit ceiling** (`clampLimit`, lines 83–85 and line 865). The module declares `maxSyncLimit` (default 5000, overridable via `GMAIL_MAX_SYNC_LIMIT`) and a `clampLimit` function that pins every caller-supplied `limit` value into `[1, maxSyncLimit]`:
   ```js
   function clampLimit(value) {
     return Math.min(Math.max(positiveInt(value, defaultLimit), 1), maxSyncLimit);
   }
   ```
   `handleMessageRoutes` applies this immediately on the inbound query string before any Gmail call is made (line 865: `const limit = clampLimit(requestUrl.searchParams.get('limit') || defaultLimit)`).

2. **Gmail page-size hard cap** (line 48). The per-page batch sent to the Gmail List API is bounded regardless of environment configuration:
   ```js
   const gmailListPageSize = Math.min(positiveInt(process.env.GMAIL_LIST_PAGE_SIZE, 500), 500);
   ```
   `loadMessageListPage` (line 525) further narrows each request to `Math.min(gmailListPageSize, limit)`, so neither the operator nor the caller can inflate a single Google API call.

3. **BaaS mirror abort timeout and error swallowing** (lines 601, 654–679). Every outbound call to the BaaS gateway is made through `baasRequest`, which attaches an `AbortSignal.timeout(baasMirrorTimeoutMs)` (default 10 000 ms):
   ```js
   signal: AbortSignal.timeout(baasMirrorTimeoutMs), // never let a hung BaaS wedge the bridge
   ```
   `mirrorMessagesToBaaS` catches any resulting error, logs a warning, and returns without re-throwing — unless `MAIL_BRIDGE_REQUIRE_BAAS=true` is set. The comment on line 654 makes the intent explicit: *"Never breaks the mail response unless MAIL_BRIDGE_REQUIRE_BAAS=true: a mirror failure is logged and swallowed so Gmail stays usable when the BaaS is down."*

**`apps/calendar/bridge/server.mjs`** — two parallel controls:

1. **Google Calendar page-size hard cap** (line 47). The events page size sent to the Google Calendar API is clamped at construction time and cannot exceed 2 500:
   ```js
   const googleEventsPageSize = Math.min(positiveInt(process.env.CALENDAR_EVENTS_PAGE_SIZE, 2500), 2500);
   ```
   It is applied directly as `maxResults` in the Google API call (line 419).

2. **Background BaaS health polling with TTL** (lines 471–488). Rather than probing the BaaS gateway synchronously on every `/health` request, `baasStatusSnapshot` returns a cached status object and triggers a background refresh at most once every `BAAS_STATUS_TTL_MS` (30 000 ms). The comment (line 474–477) explains the rationale: a live probe hangs approximately 5 seconds when the gateway is down, which caused Docker's 3-second healthcheck to mark the bridge permanently unhealthy. The TTL cache decouples bridge liveness from BaaS availability entirely.

## How we know it is applied

The controls are wired into the live request path, not behind a feature flag:

- In the mail bridge, `handleMessageRoutes` is called for every `GET /messages` request (line 907: `if (await handleMessageRoutes(request, requestUrl, response)) return;`). `clampLimit` is the first operation inside that handler (line 865), before any I/O.
- `baasRequest` is the **only** path through which the mail bridge writes to the BaaS; `AbortSignal.timeout` is unconditional inside it (line 601).
- In the calendar bridge, `baasStatusSnapshot` is the return value of the `/health` endpoint (line 673: `json(response, 200, { ok: true, provider: 'google-calendar', baas: baasStatusSnapshot() })`), meaning the background-polling isolation is exercised by Docker's own healthcheck on every probe cycle.

## Reference

The [OWASP Denial of Service Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) catalogues resource-exhaustion patterns and their mitigations, with particular emphasis on bounding inputs at the earliest possible point in the call chain and limiting blast radius from external dependencies. The controls here follow that guidance directly: the clamp happens before any Google API call is issued, and the abort timeout ensures that the BaaS dependency is a bounded, non-blocking operation.

## Residual risk / assumptions

- **No rate limiting on the bridge HTTP interface itself.** The sync-limit cap bounds the work per request but does not restrict how many requests a caller can issue per second. A high-frequency flood of even small syncs will exhaust Google API quota and bridge CPU without any additional throttle in place.
- **BaaS abort timeout is per-request, not cumulative.** Concurrent mirror calls each get their own 10-second window; under high concurrency the aggregate blocking time grows linearly.
- **`MAIL_BRIDGE_REQUIRE_BAAS=true` removes fault isolation.** When this flag is set, a BaaS outage directly surfaces as a 5xx to the user, converting the BaaS from a non-critical mirror into a hard dependency.
- **`maxSyncLimit` is operator-configurable.** An operator who sets `GMAIL_MAX_SYNC_LIMIT` to an arbitrarily large value removes the ceiling entirely; the clamping is only as strong as the deployed configuration.
- **Calendar `baasRequest` has no `AbortSignal`.** Unlike the mail bridge, the calendar bridge's `baasRequest` function (lines 456–467) does not attach an abort signal. A hung BaaS gateway during a calendar mirror call will block for the default Node.js `fetch` timeout rather than the operator-configured ceiling.
