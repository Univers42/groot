# SQL Injection Prevention — osionos-bridge (website-to-editor trust boundary)

> Every identifier and filter value that osionos-bridge forwards to PostgREST is constrained to a
> UUID-regex-validated string or a closed enum set, then percent-encoded via `URLSearchParams` or
> `encodeURIComponent`, before it is ever concatenated into a query string — ensuring no
> user-controlled input reaches the PostgREST filter layer in an un-validated, un-encoded form.

## What it is (the concept)

**SQL Injection** is an attack class in which user-supplied data is interpreted as part of a
database query rather than as a literal value, allowing an adversary to alter query logic, bypass
authorisation checks, or exfiltrate data.  In a REST proxy context the analogous risk is
**operator smuggling**: embedding PostgREST query operators (e.g. `or=`, `not.eq.`, comma-split
`in.(...)` sets) inside a value parameter so the proxy forwards a structurally different filter than
intended.  **Parameterisation** — keeping the query structure fixed and the data strictly delimited —
is the canonical prevention technique; the bridge achieves this without a SQL driver by combining
**allow-list validation** with **URL-encoding** at the layer where filter strings are assembled.

## What it defends against

See [SQL Injection](../../attack/sql-injection.md).

In the osionos-bridge context the threat is concrete: the bridge holds the PostgREST
**service-role key** and acts as the sole gateway between the React frontend and the grobase BaaS.
A request carrying a workspace or page identifier like `or=(id.eq.other-uuid)` — absent
validation — would be forwarded verbatim to PostgREST and could bypass row-level scoping.
Because the bridge also handles PATCH and DELETE operations on `osionos_pages`, a successful
injection could silently wipe or expose pages across tenant boundaries.

## How osionos-bridge implements it

All PostgREST queries are assembled through three coordinated mechanisms in
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs):

**1. `postgrestQuery` — structural URL-encoding of every filter parameter (lines 588–594)**

```js
function postgrestQuery(params) {
    const searchParams = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
        if (value !== undefined && value !== null && value !== '') searchParams.set(key, value);
    }
    return searchParams.toString();
}
```

`URLSearchParams.set` percent-encodes the value on assignment, so characters with PostgREST
operator significance (`,`, `(`, `)`, `=`) cannot survive into the query string as bare
metacharacters.  Every BaaS read path (`fetchPageRow`, `fetchPageConfigRow`, workspace listing,
etc.) routes its filters through this function before calling `baasRest`.

**2. `requireUuid` — UUID allow-list before interpolation (lines 76, 233–236)**

```js
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requireUuid(value, fieldName) {
    const normalized = safeText(value, 80);
    if (!UUID_REGEX.test(normalized)) throw Object.assign(
        new Error(`${fieldName} must be a UUID.`), { status: 422 });
    return normalized;
}
```

`requireUuid` is invoked for every identifier before it is interpolated into a PostgREST filter
expression.  Representative call-sites include `fetchPageRow` (line 795: `pageId`), workspace
access checks (line 663: `workspaceId`), and page configuration queries (line 809: `userId`).
A non-UUID value causes an immediate HTTP 422 response; no query is constructed.

**3. `idsFilter` and email hashing — `encodeURIComponent` on list and hash values (lines 917–918, 1036)**

```js
function idsFilter(ids) {
    return `id=in.(${ids.map((id) => encodeURIComponent(id)).join(',')})`;
}
```

For bulk `in.(...)` filters each element is individually encoded.  Email-derived values follow the
same discipline: the resolved email hash is passed through `encodeURIComponent` (line 1036) before
being embedded in the `email_hash=eq.${hash}` predicate used by `resolveAdminFlag`.

**4. Enum allow-listing for non-UUID fields (line 92, lines 605, 666, 706)**

```js
const PAGE_VISIBILITY_VALUES = new Set(['private', 'shared', 'public']);
```

The `visibility` field — which cannot be a UUID — is validated against this closed set before
storage or forwarding.  Any value outside the set is replaced with `'private'`; it is never
passed raw to the query layer.

## How we know it is applied

The bridge test suite at
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs)
exercises the full CRUD path through a live `createBridgeServer` instance backed by a mock fetch
that parses the forwarded `URLSearchParams` directly:

```js
it('serves Postgres-backed page CRUD routes from the bridge', async () => {
    // … creates, lists, reads, patches, and deletes pages via real HTTP through the bridge server
    const readResponse = await fetch(`${baseUrl}/api/pages/${pageId}`, { headers });
    assert.equal(readResponse.status, 200);
```

The mock fetch (lines 109–178) inspects `parsed.searchParams.get('id')` and `'workspace_id'`
after the bridge has processed the request — confirming the filter values arrive as
`URLSearchParams`-encoded strings, not as raw operator expressions.  This test runs as part of
`npm run test:bridge`, which is gated in CI (`docker compose run … playground npm run test:bridge`).

## Reference

The [SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
(OWASP) identifies **parameterised queries / prepared statements** as the primary defence and
**input validation with an allow-list** as a secondary, complementary control.  The bridge cannot
use a traditional prepared-statement API because it communicates with PostgREST over HTTP rather
than a database wire protocol; the combination of `URLSearchParams` encoding (structural
parameterisation) and UUID/enum allow-listing is the architectural equivalent for this layer.

## Residual risk / assumptions

- **PostgREST operator injection in filter values is mitigated, not eliminated by static analysis.**
  A new code path that assembles a raw query string without routing through `postgrestQuery` or
  `requireUuid` would silently bypass these controls.  There is no automated linter rule enforcing
  that every outgoing BaaS URL must pass through these helpers.
- **The bridge trusts PostgREST's own RLS enforcement** as a second line of defence.  If a novel
  filter expression were to bypass the bridge validation layer, row-level security policies on the
  grobase side would be the only remaining barrier.
- **Body payloads are serialised with `JSON.stringify` and sent as `Content-Type: application/json`**
  (see `baasRest`, line 466), so write operations (POST/PATCH) are not subject to query-string
  injection at all — but they are subject to mass-assignment risks, which are controlled separately
  by the field allow-listing in `assignPayloadValue`.
- **UUID validation uses a version 1–5 pattern.** UUIDs generated outside that version range
  (e.g. a future v7 time-ordered UUID) would be rejected with HTTP 422 until the regex is updated.
- **No SQL is written or executed by the bridge itself.** This entire control surface applies only
  to the PostgREST HTTP filter layer; direct database access does not exist in this process.
