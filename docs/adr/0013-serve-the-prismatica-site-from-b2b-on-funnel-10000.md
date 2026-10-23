# 0013. The Prismatica site and its auth gateway are served from b2b on Funnel :10000, with allowlisted signup and a number-matched approval link

- Status: accepted with conditions (PUB-1 to PUB-16, APR-1 to APR-15, SGN-1 to SGN-7; nothing built or deployed yet)
- Date: 2026-10-17
- Deciders: devil (risk ruling of 2026-10-17). The user runs every b2b step.

## Context

- b2b (tailscale 1.104.1) already funnels two hosts on :443 to the WAF at https+insecure://127.0.0.1:8443, and
  nothing on :10000 (`tailscale serve status --json`, 2026-10-17).
- The site image's nginx sends `/api/` to `OO_BAAS_UPSTREAM` with the prefix stripped. That variable defaults to
  Kong at http://mini-baas-kong:8000 (opposite-osiris `docker/services/web/default.conf.template:78-87`, groot
  `docker-compose.yml:596`). On b2b that path skips the WAF.
- The WAF's http listener proxies to Kong. `curl http://127.0.0.1:8880/rest/v1/` on the VM answered 401.
- Browser traffic passes two appending proxies, tailscaled serve and then the site nginx
  (`default.conf.template:63`). The gateway keys its rate limits on chain[len - hops]
  (`scripts/auth/net-ip.mjs:342-348`). With hops=1 every client shares the docker bridge address.
- mini-baas-redis runs with `--protected-mode no` and no password, maxmemory 384mb, volatile-lru. The root compose
  points the gateway at it (`docker-compose.yml:548`).
- Kong's verified-JWT identity fix is live: `/tmp/kong.yml` in mini-baas-kong contains `authenticated_jwt_token`
  twice.
- Whether anon can read `public.users.email` on b2b depends on migration order (`models/gdpr-migration.sql:816`
  against `models/rls-hardening-migration.sql:155-156`).
- Signup mail is sent by the gateway through `/email/v1/send` (`scripts/auth/account-mail.mjs` registerJob,
  `scripts/auth/email-api-mailer.mjs:2,9-11`), not by GoTrue. Its ceiling is therefore Kong's 10/min and 200/h on
  the gateway's single IP, not GOTRUE_RATE_LIMIT_EMAIL_SENT=30. The sender is the same Titan box that sends
  grobase prod's own mail.
- `POST /api/newsletter/subscribe` has no Turnstile (`scripts/auth-gateway.mjs:769-799`).
- The gateway boots without osionos-bridge, and its hand-off answers 503 without the bridge secret
  (`auth-gateway.mjs:865-867`).
- Unknown when this was written:
  - tailscaled's X-Forwarded-For was reasoned from its source (ReverseProxy Rewrite sets it to the funnel source
    address), not measured. PUB-1 measures it.
  - The live anon column grant on users (PUB-3).
  - Titan's daily send cap (SGN-5).

## Decision

- A separate compose project, `prismatica-public`, runs the site, the gateway and its own redis on b2b. It joins
  the external network `mini-baas_mini-baas`.
- The site publishes 127.0.0.1 only, and `tailscale funnel --https=10000` exposes it. Only the :10000 keys are
  added to the serve config.
- The gateway trusts 2 proxy hops. The site's `/api/` goes through the WAF's http listener, and the gateway's
  service-key mail and OTP calls go to Kong directly.
- Signup and newsletter subscription accept only addresses on an allowlist of domains and exact addresses. An
  empty allowlist on a public origin refuses to boot.
- A sign-in that passes the password sends one mail with a "Yes, it's me" link.
  - The link approves only when the user types the 2-digit number shown on the waiting browser.
  - A wrong number revokes the sign-in.
  - The session is released once, to the waiting browser alone.

## Alternatives considered

- **Fly**: refused by the user on cost.
- **Open signup bounded by Turnstile, verification and GoTrue's 30/h**: the 30/h does not apply to gateway mail,
  so the real bound is 200/h to any address from the shared Titan sender (`.out-of-scope/open-signup-on-the-public-demo.md`).
- **`AUTH_DEMO_INSECURE=true`**: it turns off Turnstile and verification on a public origin
  (`scripts/auth/guards.mjs:59-73`), which is an open mail relay.
- **`AUTH_TRUSTED_PROXY_HOPS=1`**: it keys every visitor to one bucket, so 8 logins/min are shared by the world
  (`auth-gateway.mjs:79`).
- **`/api/` straight to Kong**: a second public route to prod Kong with no WAF, while the WAF is on hold for
  changes (M4).
- **Two mails per sign-in (grobase code plus gateway link)**:
  - It doubles volume against the 200/h bucket.
  - The two mails arrive in either order.
  - A second "click to approve" mail is the shape phishing copies.
- **One grobase mail carrying the link**: it needs a grobase template change that takes a gateway URL, and that
  is more surface than letting the gateway own the one mail.
- **HMAC-signed approval token**: the token is random and looked up server-side, so a signature adds nothing.
- **Multiple-choice number matching**: a blind pick is right 1 time in 3. Typing 2 digits once is right 1 time in
  100.
- **Shared mini-baas-redis**: a public service would write into prod's unauthenticated, LRU-evicting redis.

## Consequences

- Colleagues get one https URL with a non-standard port. Networks that block :10000 cannot reach it, and clients
  behind one NAT share the per-IP buckets.
- Accounts, profile rows, newsletter opt-ins and mail created during the demo stay in grobase prod after the
  rollback. The rollback is `tailscale funnel --https=10000 off` followed by
  `docker compose -p prismatica-public down`.
- The allowlist is now an operator list the user maintains in the VM env.
- Residual: a real-time phishing proxy defeats number matching and codes alike. Only WebAuthn closes it.
- Follow-ups:
  - The WAF hold stays in force. Nothing here changes mini-baas-waf (PUB-10).
  - The full conditions live in `.claude/agent-memory/devil/verdict-public-site.md`.
