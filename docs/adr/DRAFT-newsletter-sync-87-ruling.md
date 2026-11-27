# DRAFT: the portal drops the post-login newsletter sync; the banner toggle is not a subscription

- Status: draft, untracked. Ruled by devil 2026-11-23. Full ruling with facts F1–F16:
  `/mnt/storage/dlesieur/scratch/me-d/RULING-newsletter-sync-87.md`.
- Scope: prismatica portal (`apps/opposite-osiris`), issue prismatica#87.

## Context

After every sign-in the portal posted the stored newsletter choice to `/api/newsletter/subscribe`
with no Turnstile token. The gateway refused it and the client swallowed the refusal, so the sync
never subscribed anyone and left one `newsletter_turnstile_failed` audit row per sign-in (seen in the
verify-password 24 h watch, 2026-11-23 16:05Z).

## Decision

Option C, PROCEED-WITH-CONDITIONS NS1–NS11: delete the sync, client only. The registration checkbox
and the footer form (which carries a Turnstile token) stay the only ways to subscribe. The banner
toggle is reworded so it no longer reads as a subscription (NS6: reworded, not removed).

## Alternatives and their costs

| Option | Verdict | Cost |
| --- | --- | --- |
| A: make the client call succeed (fresh Turnstile token on sign-in) | BLOCK | a confirmation mail on every sign-in, a second challenge, and it spends the shared mail cap |
| B: an authenticated opt-in path on the gateway | not ruled | needs a gateway deploy (VP21 forbids one for this) and server-side dedupe; gated on NS12–NS17 |
| D: keep the function, skip when there is no token | rejected | dead code that still promises a sync |

## Consequences

- Landed on prismatica develop as 995352f (+ a835911 lint cleanup), 2026-11-23.
- `prismatica-newsletter-intent-v1` is no longer written; a returning visitor's copy (it holds an
  email) is removed at startup; its cookie-policy row is gone.
- Rollback is a Vercel revert; there is no data to roll back.
- Open: NS8 prod deploy, NS9–NS10 probes, NS11 comment on #87.
