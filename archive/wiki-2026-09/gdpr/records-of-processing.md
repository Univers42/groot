# Record of Processing Activities (ROPA)

Policy version: `1.0.0`  
Last updated: 2026-05-03

This Record of Processing Activities supports GDPR Article 30 accountability for Prismatica / track-binocle.

| Processing activity | Purpose | Legal basis | Data categories | Data subjects | Recipients | Retention period | Technical safeguards | Transfer outside EU |
|---|---|---|---|---|---|---|---|---|
| Account management | Create and maintain user accounts | Contract | Email, username, password hash, profile fields, timestamps | Registered users | Hosting and infrastructure processors | Account lifetime; anonymised/deleted after verified erasure request | Hashing, RLS, JWT auth, Kong gateway, no anon password access | No intentional transfer; production must use EU/EEA or safeguards |
| Authentication and sessions | Login, session continuity, account recovery | Contract; legitimate interest in security | Password hash, session token, reset/verification token, expiry timestamps | Registered users | Infrastructure processors | Sessions: short expiry; tokens: until expiry, normally under 30 days | Private tables, RLS, no anon access, rate limiting | No intentional transfer |
| Security logging | Fraud prevention, abuse detection, troubleshooting | Legitimate interest | IP address, device/browser strings, activity type, timestamps | Users and visitors interacting with auth/API | Infrastructure processors | Maximum 13 months unless legal hold applies | RLS, private logs, minimisation, retention purge schedule | No intentional transfer |
| Consent management | Record consent and withdrawal evidence | Legal obligation; consent for optional processing | Consent type, grant/withdraw timestamps, policy version, IP/user-agent at consent | Registered users and visitors | Infrastructure processors | Account lifetime plus normally 5 years after withdrawal/closure | Dedicated consent table, versioned policies, audit logs | No intentional transfer |
| Newsletter management | Send optional product updates | Consent | Email, newsletter consent record, policy version | Users who opt in | Email processor if configured | Until withdrawal plus audit proof period | Unchecked opt-in, separate consent, withdrawal RPC | Depends on email processor; must be documented before launch |
| Data subject rights handling | Process access, deletion, rectification and portability requests | Legal obligation | Email, request type, request details, audit timestamps | Users and requesters | Internal privacy team; CNIL if required | 5 years after closure | CSRF token, audit table, manual identity verification for unauthenticated requests | No intentional transfer |
| UI preferences | Remember theme, motion and consent choices | Contract; legitimate interest; consent for optional choices | Local storage keys for theme, motion and consent | Visitors and users | Browser only unless synced after login | Until changed or cleared; consent reviewed after 13 months | Local-only storage, no tracking before consent | No transfer |
