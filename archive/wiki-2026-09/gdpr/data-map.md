# GDPR data map

Policy version: `1.0.0`  
Last updated: 2026-05-03

This inventory maps the current personal data processed by Prismatica / track-binocle. It is an operational record to support GDPR Articles 5, 6, 13, 15, 17, 20, 30 and CNIL accountability expectations.

> Important: IP addresses, browser strings, device identifiers and online identifiers are personal data under GDPR because they can identify or single out a natural person.

| Data category | Field and table | Purpose | Legal basis, Art. 6 GDPR | Retention period | Third-party sharing | Transfer outside EU |
|---|---|---|---|---|---|---|
| Email address | `users.email` | Account identifier, login, support contact, security notices | Contract for account access; legal obligation for security notices where required | Account lifetime, then anonymised within 30 days after validated deletion request unless legal retention applies | Infrastructure processors only; no sale | No intentional transfer; hosting region must be kept EU/EEA in production |
| Username | `users.username` | Public or workspace display name | Contract | Account lifetime, then anonymised on deletion | Infrastructure processors only | No intentional transfer |
| Password hash | `users.password_hash` | Authentication secret verifier | Contract; legitimate interest in security | Account lifetime; hard-deleted or irreversibly anonymised on erasure | Not shared; never exposed to frontend or anon role | No intentional transfer |
| First name | `users.first_name` | Optional profile personalisation | Consent or contract where the user supplies it for the service | Account lifetime; nulled on erasure | Infrastructure processors only | No intentional transfer |
| Last name | `users.last_name` | Optional profile personalisation | Consent or contract where the user supplies it for the service | Account lifetime; nulled on erasure | Infrastructure processors only | No intentional transfer |
| Avatar URL | `users.avatar_url` | Optional profile image reference | Consent | Account lifetime; nulled on erasure | May reference external storage if configured; currently local/demo URLs only | Depends on configured storage provider; must be EU/EEA for production unless safeguards exist |
| Biography | `users.bio` | Optional profile content | Consent | Account lifetime; nulled on erasure | Infrastructure processors only | No intentional transfer |
| Theme preference | `users.theme` | UI preference | Contract; legitimate interest in remembering interface preferences | Account lifetime or until changed | Infrastructure processors only | No intentional transfer |
| Notification preference | `users.notifications_enabled` | Notification control | Consent for optional communications; contract for essential service notices | Account lifetime or until changed | Infrastructure processors only | No intentional transfer |
| Email verification flag | `users.is_email_verified` | Account integrity and fraud prevention | Legitimate interest; contract | Account lifetime | Infrastructure processors only | No intentional transfer |
| Account timestamps | `users.created_at`, `users.updated_at` | Audit, account lifecycle, operational support | Legitimate interest; legal obligation where records are needed | Account lifetime, then retained only in anonymised aggregate/audit form | Infrastructure processors only | No intentional transfer |
| Session token | `sessions.session_token` | Session continuity and account access | Contract; legitimate interest in security | Maximum 7 days by default; immediately revoked on logout/deletion | Not shared; private table | No intentional transfer |
| Session timestamps | `sessions.created_at`, `sessions.expires_at` | Security audit and session expiry | Legitimate interest in security | Maximum 7 days after expiry, then purged | Infrastructure processors only | No intentional transfer |
| Verification/reset tokens | `user_tokens.token` | Email verification, password reset, magic-link workflows | Contract; legitimate interest in account recovery | Until expiry; normally 24 hours to 7 days depending token type | Not shared; private table | No intentional transfer |
| Token metadata | `user_tokens.token_type`, `user_tokens.created_at`, `user_tokens.expires_at` | Account recovery and audit | Legitimate interest; contract | Until expiry plus short operational audit window, maximum 30 days | Infrastructure processors only | No intentional transfer |
| Activity details | `user_activities.activity_data` JSONB containing IP address, device, browser/OS string, location text | Security monitoring, fraud prevention, troubleshooting | Legitimate interest in security and abuse prevention | Maximum 13 months per CNIL log-retention recommendation; shorter where possible | Infrastructure processors only; not used for advertising without consent | No intentional transfer |
| Activity type | `user_activities.activity_type` | Audit trail and security monitoring | Legitimate interest | Maximum 13 months unless required for dispute/legal hold | Infrastructure processors only | No intentional transfer |
| Activity timestamp | `user_activities.created_at` | Audit trail chronology | Legitimate interest | Maximum 13 months unless required for dispute/legal hold | Infrastructure processors only | No intentional transfer |
| Consent records | `user_consents.*` | Evidence of consent grant/withdrawal and policy version | Legal obligation to demonstrate consent; consent for optional processing | Duration of account plus limitation period for proof of consent, normally 5 years after withdrawal or account closure | Infrastructure processors only | No intentional transfer |
| GDPR request records | `gdpr_requests.*` | Handling access, erasure, rectification, portability and objection requests | Legal obligation | 5 years after request closure for accountability and dispute evidence | Infrastructure processors only; CNIL if required | No intentional transfer |

## Data minimisation notes

- `password_hash`, `sessions`, `user_tokens`, `user_consents` and detailed `user_activities` must never be available to the anonymous role.
- `activity_data.ip`, device strings and location strings must be purged or anonymised after 13 months unless an active security investigation or legal hold requires longer retention.
- Optional profile fields (`first_name`, `last_name`, `avatar_url`, `bio`) must remain optional and must be nulled during anonymisation.
- Newsletter and marketing consent must be separate from account creation and must never be pre-ticked.

## Transfer and processors

The local development stack does not intentionally transfer personal data outside the EU. Production deployment must select EU/EEA hosting and processors or document transfer safeguards, such as adequacy decisions or standard contractual clauses, before processing EU resident data.
