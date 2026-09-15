# Input Validation — osionos-bridge (website-to-editor trust boundary)

> Every field entering the bridge's identity-handoff path is checked against an explicit allowlist, normalized, and shaped-validated before it is used to mint a session — untrusted website payloads cannot widen privileges by injecting extra or malformed fields.

## What it is (the concept)

**Input validation** is the systematic enforcement of shape, type, format, and membership constraints on all data that crosses a trust boundary before that data is acted upon.
**Allowlist validation** (also called positive validation) defines exactly the set of keys and value shapes that are acceptable and rejects everything else, rather than trying to enumerate dangerous inputs.
**Sanitization** is the complementary step: normalizing the encoding and bounding the size of accepted values so that structurally valid but weaponized content (control characters, oversized strings, Unicode confusables) cannot reach downstream systems.
Together these two controls constitute the first line of defence at the website-to-editor trust boundary.

## What it defends against

See [Injection Attacks (SQLi, XSS, Command Injection)](../../attack/input-validation.md).

The bridge is the only path through which the opposite-osiris website can assert an identity to the osionos editor.
If arbitrary JSON keys were forwarded, an attacker in control of the website's handoff payload could attempt **mass-assignment** — inserting fields such as `is_admin`, `role`, `workspace`, or `password` into the identity assertion to escalate privileges.
Malformed identifiers (non-UUID subject/jti, syntactically invalid email) could also bypass downstream database filters or produce log injection if not rejected at the boundary.

## How osionos-bridge implements it

Two layered mechanisms operate on every inbound request, both implemented in
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs).

### 1. Handoff payload allowlist with sensitive-field rejection (`validateBridgePayload`)

```js
// line 78-79
const BRIDGE_FIELDS = new Set(['provider', 'subject', 'email', 'name', 'jti']);
const SENSITIVE_FIELD_PATTERN = /password|pass|secret|service|role|key|jwt|token|cookie|consent|birth|city|address|phone|profile|metadata|database|connection/i;
```

`validateBridgePayload` (lines 322–343) iterates `Object.keys(payload)`.
Any key absent from `BRIDGE_FIELDS` causes an immediate 422 response.
When the offending key also matches `SENSITIVE_FIELD_PATTERN`, the response body says
`'Sensitive bridge field rejected.'` rather than the generic rejection message, making
intent-specific abuse explicit in logs.

After the key check, each accepted value is further validated by type and format:

```js
if (provider !== 'prismatica') throw … { status: 422 };
if (!UUID_REGEX.test(subject)) throw … { status: 422 };
if (!EMAIL_REGEX.test(email))  throw … { status: 422 };
if (!UUID_REGEX.test(jti))     throw … { status: 422 };
```

`provider` must equal the string `'prismatica'` exactly; `subject` and `jti` must match a
strict UUID v1–v5 pattern (`/^[0-9a-f]{8}-…$/i`, line 76); `email` must pass an
RFC-style local-part + domain-label regex (lines 72–75).
`validateBridgePayload` returns only the normalized, validated fields — never the raw payload
object — so downstream code cannot accidentally access an unvalidated key.

### 2. Centralized `safeText` / `requireUuid` normalization on all untrusted strings

```js
// lines 210-216
function safeText(value, limit) {
    return String(value ?? '')
        .normalize('NFKC')
        .replaceAll(/[\u0000-\u001f\u007f]/g, '')
        .trim()
        .slice(0, limit);
}
```

`safeText` is the universal first pass applied to every external string before it enters any
further logic: NFKC Unicode normalization collapses homoglyph confusables; the control-character
strip (`U+0000–U+001F`, `U+007F`) prevents null-byte injection and log-forging; `slice` enforces
a hard length cap (32–8 000 characters depending on field).

`requireUuid` (lines 233–237) composes `safeText` with `UUID_REGEX` and raises 422 on failure —
used for every workspace, page, and database identifier received from the client.

Enum fields such as page visibility, surface type, and workspace permissions are validated against
fixed `Set` allowlists (lines 92–93, 117):

```js
const PAGE_VISIBILITY_VALUES = new Set(['private', 'shared', 'public']);
const PAGE_SURFACE_VALUES    = new Set(['page', 'agent', 'home', 'folder', 'wiki', 'app']);
const WORKSPACE_PERMISSIONS  = new Set(['create', 'read', 'update', 'delete', 'admin']);
```

Values outside these sets are rejected before any write reaches the BaaS.

The Claude-agent endpoint applies a parallel sanitization (`sanitizeClaudeRequest`, lines 1351–1373):
`maxBudgetUsd` is arithmetically clamped to `[0.01, 2]`; the `allowedTools` array is filtered to
keys present in `CLAUDE_TOOL_MAP`; `agent`/`model`/`effort` are validated against their own `Set`
allowlists (`CLAUDE_AGENT_VALUES`, `CLAUDE_MODEL_VALUES`, `CLAUDE_EFFORT_VALUES`).

## How we know it is applied

`validateBridgePayload` is called unconditionally inside `verifyBridgeRequest` (line 359) —
the single entry point for every handoff before a session token is minted.
No code path issues a session without passing through this gate.

The test suite at
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs)
contains a dedicated negative-path block (lines 231–235):

```js
it('rejects unexpected sensitive fields', () => {
    assert.throws(() => validateBridgePayload({ ...payload, password: 'nope' }), /Sensitive bridge field rejected/);
    assert.throws(() => validateBridgePayload({ ...payload, cookiePreferences: { analytics: true } }), /Sensitive bridge field rejected/);
    assert.throws(() => validateBridgePayload({ ...payload, city: 'Paris' }), /Sensitive bridge field rejected/);
});
```

These tests run under `npm run test:bridge` (executed inside the `playground` Docker service),
which is part of the CI quality gate alongside `test:quality` and `test:canvas`.

A further negative assertion in the same test suite (line 244) confirms that a serialized bridge
session contains no secret material:

```js
assert.doesNotMatch(serialized, /SERVICE_ROLE|JWT_SECRET|OSIONOS_BRIDGE_SHARED_SECRET|database_password/i);
```

## Reference

The [OWASP Input Validation Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)
establishes allowlist (positive) validation as the primary recommended strategy and explicitly
calls out the need to validate data type, length, format, and range before any processing.
The bridge's implementation follows this prescription in full: type guard (`typeof payload === 'object'`),
key allowlist (`BRIDGE_FIELDS`), format validation (UUID and email regexes), and length bounding
(`safeText` + explicit `slice` limits) are all applied before the payload is returned or stored.

## Residual risk / assumptions

- **`name` field is not format-validated beyond `safeText`.** It is length-capped at 80 characters
  and control-char-stripped, but any printable string is accepted. Code that renders `name` in HTML
  must apply output encoding independently; the bridge does not guarantee it is safe for unescaped
  HTML insertion.
- **The `context` object in Claude-agent requests receives no deep validation** (line 1361–1363):
  it is accepted as any plain object and passed to the model prompt. Malicious context keys could
  influence model behavior even if they cannot affect the DB.
- **Validation fires at the HTTP handler layer, not at a framework middleware level.** If a new
  route is added without calling `requireUuid`/`safeText`/`validateBridgePayload`, it bypasses all
  controls — there is no compile-time or lint-time enforcement of mandatory sanitization.
- **Trust is placed entirely on the `BRIDGE_FIELDS` allowlist being complete.** If a legitimate new
  field is added to the handoff schema without a corresponding entry in `BRIDGE_FIELDS` and an
  appropriate format validator, it will be rejected — a correct fail-safe — but the developer must
  remember to extend the allowlist deliberately.
