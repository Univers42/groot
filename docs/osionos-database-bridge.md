# osionos Database Bridge

## Goal

Prismatica website accounts and the osionos dashboard keep separate databases. The website owns public identity and account metadata through mini-BaaS. The osionos app owns workspace/page data in its own MongoDB. They never connect directly at the database layer.

The integration uses an HTTP bridge:

1. The user signs in through the Prismatica auth gateway.
2. The osionos app asks the Prismatica gateway for an osionos session by sending the Prismatica access token over HTTP.
3. The Prismatica gateway validates that token against mini-BaaS.
4. The Prismatica gateway signs a short-lived server-to-server bridge request with `OSIONOS_BRIDGE_SHARED_SECRET`.
5. The osionos API verifies the HMAC signature, provisions or updates a local linked user, creates an owner workspace if needed, and returns an osionos JWT.
6. The osionos frontend uses only that osionos JWT for workspace and page requests.

No SQL connection string, MongoDB URI, service-role key, or raw database access crosses this boundary.

## Identity Mapping

The osionos API stores a local user row with:

- `externalProvider = "prismatica"`
- `externalSubject = <Prismatica user id>`
- `email = <validated Prismatica email>`
- `name = <Prismatica username or email local part>`

The pair `(externalProvider, externalSubject)` is unique and sparse. If an older local account exists with the same email, the bridge attaches the external identity to that account instead of creating a second account.

The first successful bridge exchange calls `ensurePersonalWorkspace()`. That creates one workspace owned by the linked osionos user and inserts an owner membership. The owner receives `full_access` through the ABAC engine by default.

## Authorization Model

The frontend still keeps its existing UI-level access checks, but security is enforced on the osionos API:

- `GET /api/workspaces` returns only workspaces where the current osionos user has a membership.
- `GET /api/workspaces/:id` and member routes return `404` unless the caller belongs to that workspace.
- Workspace member mutations require ABAC `full_access` on the workspace.
- Page creation requires ABAC `can_edit` on the target workspace.
- Page reads require ABAC `can_view` on the page's workspace/page resource.
- Page updates, property edits, archive, and restore require ABAC `can_edit`.
- Malformed workspace/page IDs are rejected before database queries.

This means a forged `workspaceId` or `pageId` in the browser cannot reveal or mutate another user's private workspace.

## HTTP Contract

Browser to Prismatica gateway:

```http
POST /api/auth/osionos-session
Authorization: Bearer <prismatica-access-token>
```

Gateway to osionos API:

```http
POST /api/auth/bridge/session
Content-Type: application/json
X-Prismatica-Bridge-Timestamp: <milliseconds since epoch>
X-Prismatica-Bridge-Signature: <hmac-sha256>

{
  "provider": "prismatica",
  "subject": "<prismatica-user-id>",
  "email": "user@example.com",
  "name": "username"
}
```

The signature is computed over:

```text
<timestamp>.<stable-json-payload>
```

The osionos API accepts only timestamps within five minutes and compares HMAC values with a timing-safe comparison.

## Required Environment

Use the same high-entropy value on both servers:

```sh
OSIONOS_BRIDGE_SHARED_SECRET=replace-with-random-32-byte-secret
```

Website auth gateway:

```sh
OSIONOS_BRIDGE_URL=http://localhost:4000/api/auth/bridge/session
```

osionos app frontend:

```sh
VITE_PRISMATICA_AUTH_URL=/api/auth
VITE_PRISMATICA_AUTH_TARGET=http://localhost:8787
VITE_API_URL=http://localhost:4000
```

In Docker dev, `VITE_PRISMATICA_AUTH_TARGET` points to `http://host.docker.internal:8787` so the Vite container can reach the host auth gateway through HTTP.

## OWASP-Aligned Controls

- Broken Access Control: every workspace/page route checks membership or ABAC server-side.
- Identification and Authentication Failures: the app database does not accept website tokens directly; it accepts only bridge requests signed by a server-held secret.
- Cryptographic Failures: the bridge secret stays in environment variables and is never exposed to browser code.
- Injection: user-controlled IDs are validated before MongoDB queries, and route bodies do not build dynamic database commands.
- Security Logging and Monitoring Failures: the gateway records bridge success/failure audit events without logging tokens or secrets.
- SSRF: the bridge target is a fixed server-side environment URL, not a user-controlled URL.

## Operational Notes

Rotate `OSIONOS_BRIDGE_SHARED_SECRET` if either runtime environment leaks. Existing osionos JWTs remain valid until their normal expiry; force logout by rotating `JWT_SECRET` or clearing sessions if emergency revocation is required.

Do not place database credentials in browser-exposed variables. Only `VITE_*` values intended for browser code should be set in the osionos frontend container.
