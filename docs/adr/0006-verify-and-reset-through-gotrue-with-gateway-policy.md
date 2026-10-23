# 0006. Email verification and password reset: GoTrue owns the tokens, the gateway owns the policy

- Status: accepted (being built on `redesign/auth` and osionos `redesign/bridge-auth`; the baas
  migration and the real Titan send are human-run)
- Date: 2026-10-15
- Deciders: devil (ruling of 2026-10-15, `docs/redesign/verdicts/phase1-devil.md` §Decision B)

## Context

- Sign-up does not require a confirmed email, and the site has no working password reset. The
  gateway's SMTP settings use two vocabularies, so mail can leave through the wrong server (R5,
  AUDIT §5).
- GoTrue already issues random, single-use, hashed tokens and can revoke its own sessions. The
  gateway already holds the admin key and the mail path.
- The bridge verifies its own session token with a synchronous HMAC (`bridge-api.mjs:403-445`),
  and about 27 modules import that verifier. Until now nothing ended a bridge session after a
  password reset.
- The local `apps/grobase/.env` points `SMTP_HOST` at Titan, and GoTrue takes
  `${SMTP_HOST:-mailpit}` (`auth-api.yml:24-28`). A local test could therefore send real mail.

## Decision

- **GoTrue owns the tokens.** The gateway calls `generate_link` and mails the link itself, so
  GoTrue never mails a browser-facing URL.
- **The gateway signs the link** with
  `HMAC(AUTH_LINK_SIGNING_KEY; token_hash, type, exp)`. A bad signature or a past `exp` gets 410
  before GoTrue is called, so expiry is checked before the token is consumed.
- **The token travels in the fragment** (`#token_hash=…`), and the confirm and reset pages send
  `Referrer-Policy: no-referrer`. The page posts the token to `/api/auth/verify` or
  `/api/auth/reset-password`.
- **`/recover` and `/resend-verification` answer 202 before any lookup.** The work runs on one
  bounded queue: a maximum length, at most 2 SMTP sessions, overflow dropped and audited, every
  rejection caught. Both endpoints share one per-address bucket.
- **A reset ends every session.** It calls GoTrue `logout?scope=global` and writes
  `sessions_valid_after`. The bridge's single verifier refuses a token minted before that time,
  using an `iat_ms` claim.
- **Tests cannot reach Titan.** `tests/e2e/run.sh` refuses `pr*` and `dm*` unless the running
  gateway's effective `SMTP_HOST`, and a local GoTrue's `GOTRUE_SMTP_HOST`, is Mailpit.

## Alternatives considered

- **A gateway-owned token table**: GoTrue is still the only party that can confirm an email, set
  a password or revoke a session, so the table adds a second token store and a migration on the
  shared database without removing the dependency. The one gain, expiry checked before
  consumption, is the signed link above in about 20 lines.
- **The token in a query string**: it lands in access logs and in `Referer`.
- **Revocation by access-token lifetime alone**: a stolen session would outlive the reset by up
  to an hour.

## Consequences

- Verdict: PROCEED-WITH-CONDITIONS. Conditions 1–14 of phase1-devil.md §Verdict B are the
  acceptance criteria. Among them:
  - 0 GoTrue calls for an expired or tampered link (1);
  - no token in any access log (2);
  - a resend keeps the sign-up password (3);
  - a TOTP user can reset, or a dated DECISIONS entry says they cannot (4);
  - the enumeration surface is stated honestly: `/availability`, `/register` 409 and `/login`
    timing (5);
  - a bridge token minted 1 ms before the cutoff is refused and one minted 1 ms after is
    accepted (8);
  - logout with only the cookie revokes it (10);
  - the planted-Titan refusal is mutation-tested (11);
  - no test users are created on baas (12);
  - verification turns on in the same change as its Mailpit test (13);
  - a preflight fails when `GOTRUE_MAILER_OTP_EXP` is set below 86 400 (14).
- The bridge side is built (osionos `redesign/bridge-auth`):
  - the cutoff check has a 5 s cache; a failed lookup answers 503, and an allowed request is
    audited;
  - viewer members get read-only access to mounts (R17);
  - the Share dialog writes collaborators.
- A groot migration adds the `sessions_valid_after` column. It is service_role-only and must pass
  `make models-grants-verify`. Applying it on baas is human-run.
- Residuals, stated rather than claimed away:
  - other sessions' GoTrue access JWTs stay valid for up to 3600 s at services that check only
    the signature (condition 9);
  - queued mail is lost on a restart;
  - an attacker can use up a victim's three requests an hour.
- The one real Titan send is the final step of Phase 7 and needs the user's approval.
