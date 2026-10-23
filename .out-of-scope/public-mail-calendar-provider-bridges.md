# Public Mail and Calendar with real provider accounts are out of scope

- Decided: 2026-10-18 · by devil (Mail and Calendar Phase A ruling, ADR 0020)
- Holds while: the bridges keep one account in one file and no route is authenticated.

## The concept

Strangers on the public deployment connect their own Gmail or Google Calendar through the mail and
calendar bridges.

## Why not

- Each bridge holds one account in one file, and no route is authenticated (mail `server.mjs:39,834-864`;
  calendar `server.mjs:39,89,730-771`).
- Calendar sends real mail through Google (`sendUpdates=all`).
- The mirror writes to prod with the service role, and its tables have no owner.
- The Vite dev server serves the token file.
- Google's restricted-scope gate caps an unverified app at 100 named users with 7-day tokens (external
  knowledge, not measured here), which makes open sign-up on real Gmail impossible by definition.

## Prior requests

- 2026-10-18 (coordinator): real accounts through the bridges, as submitted before Phase A.

## Reopen when

All of these hold:

1. Tokens are stored per osionos user, encrypted at rest, and bound to a session with signed
   `emailVerified===true`.
2. OAuth state is bound to that session, with PKCE.
3. CORS allows one exact origin and every route needs auth.
4. `/baas/mirror` is gone; the mirror is either off or owner-scoped under RLS, through a migration path not
   blocked by ML-6 and ML-7.
5. `sendUpdates` defaults to `none`, and any send path (invites or `gmail.send`) gets its own devil review.
6. The token store is outside every web root.
7. The Google consent screen is verified for the scopes in use, on a domain the project can verify.
