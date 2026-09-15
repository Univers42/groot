# Data Protection / GDPR — mail and calendar (Google OAuth apps)

> The mail bridge strips Gmail message bodies from every row written to the BaaS cache, so raw email content never leaves the authoritative source (Gmail) and is never stored in the secondary datastore.

## What it is (the concept)

**PII minimisation** is the GDPR principle (Art. 5(1)(c)) requiring that personal data be **adequate, relevant, and limited to what is necessary** for the stated purpose. In a caching or mirroring architecture the risk is that a secondary store accumulates a full copy of sensitive data, widening the blast radius of any future exposure. The control here is a deliberate **data-shape boundary**: the structured query columns (sender, subject, timestamps, flags) satisfy the app's search and rendering needs; the raw body — the highest-density PII — is excluded from the mirror entirely.

## What it defends against

Concentration of email-body PII in the secondary BaaS cache; see [Sensitive Data Exposure](../../attack/data-protection-gdpr.md). If the BaaS PostgREST endpoint, its service key, or the `mail_messages` table were compromised, an attacker would obtain metadata rows but not the contents of any email — those stay exclusively in Gmail under Google's custody and the user's OAuth grant. The threat is especially acute for a multi-account bridge where a single service-role key can read every cached row.

## How mail-calendar implements it

The single row mapper in [`apps/mail/bridge/server.mjs`](../../../../apps/mail/bridge/server.mjs) (line 620) constructs every `mail_messages` record that reaches the BaaS. At lines 644–646 it deliberately sets `body` and `bodyHtml` to `undefined` before spreading the Gmail API response object into `source_payload`:

```js
// Metadata only — keep raw bodies out of the mirror (the structured columns above carry
// what other apps query; bodies stay in Gmail to limit PII concentration in the cache).
source_payload: { ...message, body: undefined, bodyHtml: undefined },
```

The `source_payload` column therefore contains the original Gmail envelope minus the body fields. All other structured columns (`from_email`, `subject`, `received_at`, `is_unread`, etc.) are mapped explicitly from parsed fields — they carry no raw body content.

## How we know it is applied

`messageRecord` is the **only** mapper in the bridge file and is called at exactly one call-site (line 665) inside `mirrorMessagesToBaaS`:

```js
const records = messages
  .map((message) => messageRecord(accountId, account, message))
  .filter((record) => record.provider_message_id);
```

There is no alternative code path that writes `mail_messages` rows with bodies present. `grep -n "function messageRecord\|messageRecord(" apps/mail/bridge/server.mjs` returns exactly two hits: the definition (line 620) and this map call (line 665) — confirming zero additional usages. Any future writer that bypasses `messageRecord` would have to explicitly add body fields; the default (spread + override) produces the safe shape.

## Reference

OWASP classifies inadequate protection of sensitive data at rest under **A02:2021 – Cryptographic Failures** ([https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)), which covers cases where data that should never be stored is stored unencrypted or unnecessarily. The minimisation control here addresses the upstream failure mode: data that is never written to the secondary store cannot be exposed by that store, regardless of the encryption posture applied to it.

## Residual risk / assumptions

- **Body fragments in subject lines.** Some senders embed message content in the subject field, which _is_ stored. The control does not inspect or redact subject content.
- **Attachment metadata.** `has_attachments` (boolean) is stored; attachment filenames are not explicitly excluded from `source_payload` if the Gmail API returns them at the message envelope level rather than in a separate `body` field.
- **Calendar app.** No equivalent body-stripping control has been identified in `apps/calendar`. If the calendar bridge mirrors event descriptions (which may contain meeting links, personal notes, or health data), a parallel control should be introduced there.
- **Google OAuth trust.** The control assumes Google's API does not silently move body content into a field other than `body` / `bodyHtml`. Any Gmail API response schema change could inadvertently re-introduce body content into `source_payload` without a test catching it — there is currently no automated assertion that verifies `body` is absent from written rows.
- **Service key scope.** `mirrorMessagesToBaaS` uses the BaaS service role key (`baasServiceKey`), which bypasses Row Level Security. Minimising the written data reduces but does not eliminate the value of obtaining that key.
