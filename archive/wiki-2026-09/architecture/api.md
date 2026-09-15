# GDPR API

Policy version: `1.0.0`  
Last updated: 2026-05-03

All endpoints are exposed through PostgREST under the public Kong gateway. Authenticated endpoints require a valid user JWT in `Authorization: Bearer <token>` and the public `apikey` header. Kong rate limiting must remain enabled on `/rest/v1` and `/rpc` routes.

## Art. 15 and Art. 20 — access and portability

`POST /rest/v1/rpc/gdpr_export_my_data`

Returns a structured, machine-readable JSON export for the calling user. The response includes labelled sections for:

- `users` without `password_hash`
- `user_tokens` without raw token values
- `sessions` without raw session token values
- `user_activities`
- `user_consents`

The JSON can be given directly to the user. A CSV export endpoint should be added in a future iteration for additional portability formats.

Example response shape:

```json
{
  "policy_version": "1.0.0",
  "generated_at": "2026-05-03T00:00:00Z",
  "data_subject": { "user_id": 1, "email": "john.doe@example.com" },
  "users": {},
  "user_tokens": [],
  "sessions": [],
  "user_activities": [],
  "user_consents": [],
  "format": "machine-readable JSON; CSV export planned for a future iteration"
}
```

## Art. 17 — erasure request

`POST /rest/v1/rpc/gdpr_request_deletion`

Sets `users.deletion_requested_at = NOW()` for the calling user and inserts an audit row in `gdpr_requests`. The response confirms the expected deletion/anonymisation deadline, 30 days after request receipt.

Example response:

```json
{
  "status": "received",
  "request_type": "deletion",
  "user_id": 1,
  "expected_deletion_at": "2026-06-02T00:00:00Z",
  "message": "Deletion request recorded."
}
```

## Art. 7 — consent withdrawal

`POST /rest/v1/rpc/gdpr_withdraw_consent`

Body:

```json
{ "consent_type": "newsletter" }
```

Supported consent types are `terms`, `newsletter`, `analytics`, and `marketing`. The function sets `withdrawn_at` and keeps the record for audit evidence.

## Newsletter opt-in and opt-out

`POST /rest/v1/rpc/gdpr_request_newsletter_optin`

Body:

```json
{ "email": "person@example.com" }
```

Creates a pending double opt-in record. Production email delivery should send `newsletter-confirm.html` with a one-time token and must not subscribe the address until confirmation.

`POST /rest/v1/rpc/gdpr_confirm_newsletter_optin`

Body:

```json
{ "token": "one-time-token-from-email" }
```

Confirms the pending newsletter opt-in and records newsletter consent evidence where the address maps to a local user.

`POST /rest/v1/rpc/gdpr_set_newsletter`

Body:

```json
{ "granted": true }
```

Upserts a `newsletter` consent record for the calling user. The active policy version is stored with the consent record.

Unauthenticated one-click unsubscribe links may call `gdpr_withdraw_consent` with a valid newsletter token:

```json
{ "consent_type": "newsletter", "token": "one-time-token-from-email" }
```

## Public data-rights request form

`POST /rest/v1/rpc/gdpr_submit_request`

Body:

```json
{
  "request_type": "access",
  "email": "person@example.com",
  "details": { "message": "Please process my request." }
}
```

This endpoint allows unauthenticated users to file a request by email address. Such requests must be verified manually before any data disclosure or deletion.

## Security requirements

- Anonymous users must not access `user_consents`, `user_activities`, `sessions`, `user_tokens`, or `users.password_hash`.
- Authenticated users may only read and modify their own rows.
- Every data-subject RPC writes an audit record to `gdpr_requests`.
- Optional consent is not bundled with account creation or service access.
