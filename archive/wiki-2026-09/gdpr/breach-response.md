# GDPR breach response procedure

Policy version: `1.0.0`  
Last updated: 2026-05-03

This procedure supports GDPR Articles 33 and 34.

## 1. Detect and triage

Potential breach signals include:

- Unauthorised access to Postgres, Kong, GoTrue or container hosts.
- Exposure of `users.password_hash`, `sessions.session_token`, `user_tokens.token` or `user_activities.activity_data`.
- Unexpected public access to private PostgREST tables.
- Lost credentials, leaked environment files, exposed registry secrets or compromised CI/CD tokens.
- Security suite failures affecting personal data protections.

Immediate triage must record:

- Detection time and reporter.
- Systems affected.
- Categories and approximate number of data subjects affected.
- Categories and approximate number of records affected.
- Whether special-category data is involved.
- Initial risk assessment for rights and freedoms of natural persons.

## 2. Contain

- Rotate exposed API keys, JWT secrets, registry tokens and database passwords.
- Disable affected routes or services if required.
- Preserve logs and evidence before destroying containers or volumes.
- Snapshot relevant database state for forensic review if legally appropriate.
- Revoke sessions and reset affected credentials where needed.

## 3. Assess notification obligations

Under GDPR Article 33, notify the CNIL within 72 hours after becoming aware of a personal data breach unless the breach is unlikely to result in a risk to rights and freedoms.

CNIL notification portal: https://notifications.cnil.fr/notifications/index

The CNIL notification must include, where available:

- Nature of the breach.
- Categories and approximate number of data subjects.
- Categories and approximate number of records.
- DPO or contact point details.
- Likely consequences.
- Measures taken or proposed.

If all details are not available within 72 hours, send an initial notification and provide updates without undue delay.

## 4. Notify affected users when required

Under GDPR Article 34, notify affected users without undue delay if the breach is likely to result in a high risk to their rights and freedoms.

User notification must be clear and plain language and include:

- What happened.
- What data was affected.
- Likely consequences.
- Measures taken.
- Recommended user actions.
- Privacy contact details.

## 5. Document and remediate

Every breach, even when not notified to the CNIL, must be documented internally with:

- Timeline.
- Facts and evidence.
- Risk assessment.
- Decisions and rationale.
- Containment and remediation actions.
- Follow-up controls and test results.

After remediation:

- Run `npm run test:security`.
- Verify GDPR RPC protections and RLS grants.
- Review logs for recurrence.
- Update this procedure and the ROPA if processing changed.
