# mailBridge — the backend-for-frontend client (mail)

> **In one sentence.** mailBridge is a type-safe REST client that bootstraps OAuth sessions, syncs paginated mail messages, and applies actions to individual emails through a unified backend-for-frontend gateway.

## What it is & why it exists

mailBridge is a thin, opinionated HTTP abstraction layer in the mail app's frontend. It exports five public functions (`loadBridgeSession`, `openBridgeAuth`, `syncBridgeMessages`, `loadBridgeMessage`, `applyBridgeAction`, `disconnectBridge`) and one state mapper (`bridgeSessionToConnector`). Each function targets a specific endpoint on the [backend-for-frontend](glossary.md#bff) (BFF), which itself abstracts away the differences between Gmail, Outlook, and IMAP protocols. The client uses TypeScript generics and a single reusable JSON parser to ensure all responses are validated and typed consistently, turning HTTP errors into descriptive Errors with user-friendly messages.

## How it works

- `bridgeBase()` normalizes the endpoint URL by trimming whitespace and trailing slashes, so all requests use a consistent base path.
- `readJson<T>()` is a generic parser: it safely attempts to parse response JSON (returning `{}` if malformed), checks HTTP status, extracts error messages from the response body, and casts success payloads to the expected type `T`.
- `loadBridgeSession()` calls `/session` to bootstrap: it fetches the current account, provider, connection status, and last sync time from the BFF.
- `openBridgeAuth()` opens a new browser window to `/auth/{provider}/start` with [same-origin](glossary.md#same-origin) security flags (`noopener`, `noreferrer`) so the [OAuth](glossary.md#oauth) flow cannot hijack the parent window.
- `syncBridgeMessages()` constructs a [URLSearchParams](glossary.md#urlsearchparams) query string with `limit`, optional [pageToken](glossary.md#pagination-token), paging flag, and `includeBodies` toggle, then fetches `/messages` to retrieve a page of emails and the next token.
- `loadBridgeMessage()` wraps `messageId` in [encodeURIComponent()](glossary.md#encodeuricomponent) and fetches `/messages/{id}` to retrieve a single message with full body.
- `applyBridgeAction()` sends the current message state (starred, unread, mailbox) alongside the action to `/messages/{id}/actions`; the BFF reconciles concurrent changes.
- `disconnectBridge()` makes a POST to `/disconnect` to revoke the OAuth session and reset the connector state.
- `bridgeSessionToConnector()` transforms a `BridgeSessionResponse` into `ConnectorState`, merging the BFF response with the app's internal state shape.
- `bridgeErrorStatus()` extracts a human-readable error message for display in the UI.

## The code that does it

**What to look at:** Generic type-safe JSON parser that decouples fetch error handling from response parsing; loadBridgeSession bootstraps the connector state.

```ts
// apps/mail/src/lib/mailBridge.ts:51-63
async function readJson<T>(response: Response): Promise<T> {
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = typeof payload?.message === 'string' ? payload.message : `Mail bridge returned HTTP ${response.status}`;
    throw new Error(message);
  }
  return payload as T;
}

export async function loadBridgeSession(endpoint: string): Promise<BridgeSessionResponse> {
  const response = await fetch(`${bridgeBase(endpoint)}/session`);
  return readJson<BridgeSessionResponse>(response);
}
```

**What to look at:** OAuth popup window spawning with security flags; pagination abstraction via URLSearchParams builds query strings from token and limit parameters.

```ts
// apps/mail/src/lib/mailBridge.ts:65-77
export function openBridgeAuth(endpoint: string, provider: MailProvider) {
  const authWindow = globalThis.open(`${bridgeBase(endpoint)}/auth/${provider}/start`, '_blank', 'noopener,noreferrer');
  if (!authWindow) throw new Error('The browser blocked the provider authorization window.');
}

export async function syncBridgeMessages(endpoint: string, limit = 2000, pageToken = '', includeBodies = false): Promise<BridgeMessagesResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (pageToken) params.set('pageToken', pageToken);
  if (pageToken || limit < 2000) params.set('paged', 'true');
  if (includeBodies) params.set('includeBodies', 'true');
  const response = await fetch(`${bridgeBase(endpoint)}/messages?${params}`);
  return readJson<BridgeMessagesResponse>(response);
}
```

**What to look at:** Mutation endpoint shows idempotent state snapshot pattern; encodeURIComponent guards against malformed provider IDs in URL paths.

```ts
// apps/mail/src/lib/mailBridge.ts:89-97
export async function applyBridgeAction(endpoint: string, message: MailMessage, action: HoverActionId) {
  if (!message.providerMessageId) return;
  const response = await fetch(`${bridgeBase(endpoint)}/messages/${encodeURIComponent(message.providerMessageId)}/actions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, current: { starred: message.starred, unread: message.unread, mailbox: message.mailbox } }),
  });
  await readJson<{ ok: boolean }>(response);
}
```

## Where it sits in the app

Positioned at the UI-to-backend boundary: the user interacts with React components → which call mailBridge functions → which fetch from the BFF `/session`, `/auth`, `/messages`, `/actions`, `/disconnect` endpoints → which in turn route to Gmail/Outlook/IMAP backend APIs. mailBridge is the sole HTTP client; all email data flows through it.

## Remember this

> mailBridge trades verbosity for safety: one generic JSON parser, one error handler, one endpoint normalizer, and TypeScript types on every response ensure that new functions, new providers, and new error cases all fit the same pattern.

---
**See also:** [useAuth-client.md](useAuth-client.md) · [useGraphEngine.md](useGraphEngine.md) · [mail-cache.md](mail-cache.md) · [formula-engine-wasm.md](formula-engine-wasm.md) · [Glossary](glossary.md)
