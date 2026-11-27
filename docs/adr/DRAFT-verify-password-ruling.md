# DRAFT. The gateway checks a step-up password behind a raw-body HMAC that fails as "unavailable", through a stateless grant whose session is revoked with scope=local

- Status: proposed (draft, unnumbered). devil 2026-11-22: PROCEED-WITH-CONDITIONS VP1–VP22.
- Date: 2026-11-22
- Deciders: devil (ruling); opposite-osiris builder + operator (live with it). Issues: osionos #234/#232, bridge half osionos PR #322.
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-verify-password.md`

## Context

References are to opposite-osiris `origin/develop` edd3e81 and osionos `origin/main` 1712b9649.

- The bridge asks `POST {AUTH_GATEWAY_URL}/api/auth/verify-password` with an HMAC over `${ts}.password.${path}.${rawBody}`. It maps 401/403 → wrong password, 429 → limited, and anything else → 503 (`scripts/bridge-account-sudo-password.mjs:83-114`).
- `/api/auth/*` is internet-reachable by prefix. VM Funnel `:8443` sends `/api/auth` to host `:8787` (live `tailscale serve status`). That server proxies `location /` to the gateway (`groot-wt/deploy/tls/nginx.conf:249-257`). Vercel rewrites to the same place (opposite-osiris `vercel.json:16`). The bridge itself uses `http://auth-gateway:8787` on the docker network.
- The same secret already lets its holder mint bridge sessions for any user (`scripts/auth-gateway.mjs:125-129`).
- `gotrue.logout(token, scope)` takes a free scope string (`scripts/auth/gotrue-api.mjs:50`). `local` is used at three call sites, `global` at `auth/link-flows.mjs:83`. Tests mock GoTrue only.
- The SDK grant stores the session in the shared `publicBaas` client and times out after 15 s (`vendor/grobase-js/lib/domains/auth.js:47-54`, `lib/core/http.js:26`).
- Live `AUTH_TRUSTED_PROXY_HOPS=2`, and the bridge appends one more hop (`bridge-account-sudo-password.mjs:67-71`), so the gateway's `clientIp` names the proxy for every step-up.
- `readJson` decodes chunk by chunk (`auth-gateway.mjs:143-150`).
- Live image `track-binocle/prismatica-auth-gateway:local` would be overwritten by a build.
- Unknown when this was written: whether GoTrue v2.188.1 `scope=local` revokes only the token's own session. Upstream says it does, but it is unproven here (VP11).

## Decision

`scripts/auth/verify-password.mjs` serves the route:
- An empty secret answers 503 first.
- The HMAC is computed over the raw bytes, with the fixed path, a 60 s window and a single-use marker. A signature failure answers 400 and writes nothing durable, so the bridge says "unavailable", never "wrong password".
- The per-account login lockout is shared. No per-IP bucket is shared with `login`.
- The grant is a stateless `gotrue-api` password grant. On success its session is revoked with the literal `scope=local`.
- GoTrue 429 and upstream failures answer 503.
- No token, email or cookie appears in any answer. The success path sends no mail.
- The client address is computed with hops+1.

## Alternatives considered

- **The plan as written (403 on a bad signature, SDK `signInWithPassword`, login per-IP bucket)**:
  - A secret mismatch or a replay tells every user their password is wrong and burns their 5-per-15-min bridge budget.
  - The SDK leaves the minted token in shared memory, and its 15 s timeout outlives the bridge's 8 s.
  - One 8/min bucket would serve every step-up on the stack.
- **A SECURITY DEFINER RPC comparing `auth.users.encrypted_password`**: it mints no session, but it puts a password oracle behind PostgREST and skips GoTrue's ban and confirmation checks.
- **Check the password in the bridge against GoTrue directly**: it gives a stolen session a second guess budget, which is what the bridge header rules out (`bridge-account-sudo-password.mjs:25-28`).

## Consequences

- VP1–VP22 are the builder's acceptance criteria. VP11 needs a real-GoTrue proof before deploy. VP19 needs a `:pre-verify-password` tag before the build.
- The route stays internet-reachable, with the HMAC as its only guard. Denying it at the `:8787` edge is optional hardening and needs its own go.
- The bridge promotion stays a separate step after VP20 (ADR 0067 conditions unchanged).
