# 0018. The groot frontends are served on the host's Funnel, with open sign-up behind email verification

- Status: accepted with conditions (R1-R4 and G1-G8 below; the gates are what `make public-up` verifies)
- Date: 2026-10-18
- Deciders: devil (two rulings of 2026-10-18: BLOCK as submitted, then PROCEED-WITH-CONDITIONS for the
  repair). The user runs every step that touches baas.

## Context

- The website, the osionos app and the bridge run on this host and are linked to prod baas. The request:
  serve them to the internet at `https://osionos.tail10f2ea.ts.net` through Tailscale Funnel, and let
  anyone with a mailbox sign up.
- The first ruling blocked the plan as submitted, for these measured reasons:
  - The app rebuild baked `VITE_BAAS_API_KEY` (byte-equal to the bridge's tenant key) and a realtime token
    with no `namespaces` into a public bundle. The token reaches every topic unless baas sets
    `SECURITY_MODE=max`.
  - baas GoTrue answered `disable_signup:false, mailer_autoconfirm:true`. Anyone could mint a confirmed prod
    account at `/auth/v1/signup`, so the gateway's signup allowlist gated nothing.
  - `POST /api/agent/claude/stream` has no session check and spawns a child with the bridge's environment. It
    failed closed only because the bridge image ships no `claude` binary.
  - The bridge forwards no `X-Forwarded-For` to the gateway, so every app sign-in shares one rate bucket.
- Open sign-up makes bridge authorization (an IDOR against a stranger's session) the main risk. Nothing in
  the plan measured it.
- Unknown when this was written: how tailscaled 1.104.1 sets `X-Forwarded-For` on Funnel, and whether
  GoTrue's admin `generate_link` honours `DISABLE_SIGNUP`.

## Decision

- Funnel ports, and nothing else (`scripts/public-funnel.sh`, `FUNNEL_MAP`):

  | Public port | Serves | Loopback target |
  |---|---|---|
  | 443 | website, gateway `/api/auth`, Kong `/api/*` | 4322 |
  | 8443 | osionos app | 3001 |
  | 10000 | osionos bridge | 4000 |

  The runbook ([public-funnel](../../wiki/runbooks/public-funnel.md)) owns the procedure, the forced-empty
  variables and the verify checks. This ADR does not restate them.
- The public images carry no server credential (R4): the bundles are built with the keys and the realtime
  token empty, and `verify` greps both images for each secret value.
- Sign-up is open and proven by email, not by an allowlist (R2b, R3a):
  - On baas, `GOTRUE_DISABLE_SIGNUP=true` and `GOTRUE_MAILER_AUTOCONFIRM=false`. Turning autoconfirm off
    alone would let GoTrue mail anyone from the prod sender at its own rate limit, outside the gateway's cap.
  - The gateway registers through admin `generate_link` and sends the mail with `/email/v1/send`, under
    `AUTH_MAIL_DAILY_CAP` of 50 or less. The bridge signs `emailVerified` into the request it forwards.
- Chat and user realtime topics use a per-topic, 15-minute, subscribe-only token minted by the bridge (R1c),
  not a shared token.
- Opening is staged: 443 alone first, then 8443 and 10000 after the hop count is measured (G4).

## Conditions (devil)

| | Condition |
|---|---|
| R1 | Bridge: the Claude route is off on a public deployment (R1a); `emailVerified` is a strict boolean and only `true` can promote an admin (R1b); chat and user realtime tokens as above (R1c) |
| R2 | Gateway: `emailVerified` signed into the bridge request (R2a); open sign-up refuses to boot with verification off, `AUTH_DEMO_INSECURE`, a daily cap above 50 or no register limit; IPv6 keyed by /64 (R2b) |
| R3 | baas: GoTrue settings above (R3a, user-run); WAF rule 10150 for HTML mail only after R2b's cap is live (R3b, see [ADR 0012](0012-waf-rule-10150-lifts-xss-on-the-email-body.md)) |
| R4 | `public-funnel.sh verify` checks node name, exactly 3 ports, secret grep 0 on both images, bridge and gateway environment, the Claude route and geocode limits, `.env.public` ignored and mode 600 |
| G1 | R1, R2 and R4 merged and their checks pass, bridge deployed before gateway |
| G2 | Every address in `OSIONOS_ADMIN_EMAILS` exists in baas `auth.users`, and the user signs in with each |
| G3 | R3a done; no recent direct `/auth/v1/signup` callers, or the user accepts the breakage |
| G4 | `AUTH_TRUSTED_PROXY_HOPS` measured from an off-tailnet client, then set |
| G5 | `gatewayCall` forwards `x-forwarded-for`, or the user accepts in writing that one client can 429 every app sign-in |
| G6 | Two-account probe: B cannot read, change or delete A's workspace, page, database link, private channel, DM, comment or upload, nor get a realtime token for A's channel; plus a `security` review of every bridge route that takes an id |
| G7 | The user writes the residue query (new `auth.users` and `osionos_*` rows since T0) before opening |
| G8 | R2b's cap test is green and R3b is deployed |

Kill criterion: on the first day the mail cap is hit, or when 10 or more sign-ups arrive from one /24 or /64
within an hour, set `AUTH_SIGNUP_OPEN=false`. Turnstile then becomes a precondition to reopen.

## Measured (2026-10-18)

- G1-G8 were met before 8443 and 10000 opened: R1, R2 and R4 pushed (osionos main `f534938c`, opposite-osiris
  `b36385f`, groot `bd969637`); G4 tailscaled replaces a client-sent `X-Forwarded-For`, so 3 hops hold; G6
  two-account probe 37 pass, 0 fail; G7 residue 0 new `auth.users` rows since 16:30 UTC; G8 WAF 10150 deployed
  (user-run).
- `scripts/public-funnel.sh verify` at 19:50 CEST, with 443, 8443 and 10000 open: 29 pass, 0 fail, 0 skip.
- GoTrue with `DISABLE_SIGNUP=true` and `AUTOCONFIRM=false`: anonymous `/signup` answers 422
  `signup_disabled`; an unverified password login answers 400 `email_not_confirmed`; the gateway's register
  goes through admin `generate_link` and `/email/v1/send`.
- `AUTH_TRUSTED_PROXY_HOPS=3` was measured for both paths, the website and the bridge. Over-setting it makes
  the gateway fall back to the spoofable `chain[0]`.
- A tailscaled started with `--state=mem:` and no statedir serves `SSL_ERROR_INTERNAL_ERROR_ALERT` to every
  Funnel visitor. The node runs with `--state=<file> --statedir=<dir>`.

## Consequences

- Anyone with a mailbox can hold a session on a bridge that writes prod with the service key. The bound is
  email verification, the daily cap and the per-IP limits, not Turnstile. Turnstile is not required;
  `AUTH_TURNSTILE_OPTIONAL=true` lets the bridge's fixed token pass.
- App sign-up through the bridge stays refused (422): the app sends users to the website to register.
- Redis for the rate limits and the cap runs without persistence (`--save ""`). A restart resets the daily
  cap, the limits and the lockouts.
- An open realtime subscription outlives its token and survives removal from a channel until the socket
  closes. A grobase issue is owed for closing sockets at `exp`.
- Rollback: `make public-down` (`tailscale funnel reset`) closes the ports at once. It does not remove the
  accounts, content or mail that strangers created; G7's query lists them. If the bundle check ever failed,
  rotate the tenant key and `JWT_SECRET`, since the old realtime token lives 30 days.
- Not verified: bridge authorization against strangers beyond G6's probe, baas Kong and WAF per-IP limits
  (one stranger who trips a ban on the shared relay hits everyone), and Titan's own send limit.
- Reverse this by `make public-down`; the signup decision reverses with `AUTH_SIGNUP_OPEN=false`.
  This reopens [`open-signup-on-the-public-demo`](../../.out-of-scope/open-signup-on-the-public-demo.md): its
  reopen condition, a gateway daily mail ceiling proven below Titan's cap by a test, is R2b's cap (50 or less)
  with G8's test. Account mail still shares the prod Titan sender.
