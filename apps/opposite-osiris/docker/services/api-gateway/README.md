# prismatica-auth-gateway — the custom API gateway (auth BFF)

A self-contained image of [`scripts/auth-gateway.mjs`](../../../scripts/auth-gateway.mjs):
the secure **server-side broker** between the website's account/business model and
the app (osionos). Published to Docker Hub as **`dlesieur/prismatica-auth-gateway`**.

It is the component that **connects an account to the app securely** — it issues
the single-use osionos bridge session (`osionos_v1.` token) the editor consumes.

## Why it's a separate image from the website

It holds **server-only secrets** that must never reach a browser or a static site:

| Secret (runtime env) | Used for |
| -------------------- | -------- |
| `SERVICE_ROLE_KEY` | privileged BaaS/Postgres ops (bypasses row security) |
| `OSIONOS_BRIDGE_SHARED_SECRET` | minting the osionos session that links account → app |
| `TURNSTILE_SECRET_KEY` | Cloudflare Turnstile verification |
| `SMTP_*` | sending verification / alert emails |

These are **injected at runtime** (env / Vault) — the image bakes none of them
(verified: no `.env` in the image). The browser only ever sees the public anon key
(baked into the *website* image, not this one).

## What's in the image

`node:22-alpine` + the gateway script + the email templates it renders
(`src/email-templates/*.html`) + the built `@mini-baas/js` SDK (its only npm dep,
which itself has no runtime deps). No workspace mount, no source tree. ~163 MB.

## Run

It listens on `:8787` and serves `/api/auth/*` and `/api/newsletter/*`. The website
image proxies those paths to it (`OO_AUTH_UPSTREAM`).

```bash
docker run -d --name auth-gateway -p 8787:8787 \
  -e PUBLIC_BAAS_URL=http://kong:8000 \
  -e OSIONOS_BRIDGE_URL=http://osionos-bridge:4000/api/auth/bridge/session \
  -e PUBLIC_SITE_URL=https://your-site \
  -e SERVICE_ROLE_KEY=...        # from Vault — never commit \
  -e OSIONOS_BRIDGE_SHARED_SECRET=... \
  -e TURNSTILE_SECRET_KEY=... \
  -e SMTP_HOST=... -e SMTP_PORT=... -e SMTP_USERNAME=... -e SMTP_PASSWORD=... \
  dlesieur/prismatica-auth-gateway:latest
```

Talks to: BaaS/Kong (auth + service-role DB ops), the osionos-bridge (session
mint), Cloudflare Turnstile, and SMTP.

## Key dependencies

- `PUBLIC_BAAS_URL` → BaaS gateway (Kong) for auth + data.
- `OSIONOS_BRIDGE_URL` + `OSIONOS_BRIDGE_SHARED_SECRET` → the osionos bridge that
  provisions the editor session. This is the account → app secure handoff.

Verified end-to-end with the Playwright playground (account signup → bridge token
consumed by osionos → persistence), running purely from this image plus the
`dlesieur/opposite-osiris-web` image.
