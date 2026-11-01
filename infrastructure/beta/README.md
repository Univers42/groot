# osionos develop beta (ADR 0040)

https://baas.tail10f2ea.ts.net:8444/ (tailnet only) serves osionos `origin/develop`, rebuilt by a
systemd user timer within ~3 minutes of a push, against production's bridge and data.
Conditions B1–B12: `docs/ops/beta-develop-verdict-2026-11-01.md`.

## Where it runs

| Piece | Where |
|---|---|
| Checkout, `build.env`, `deployed` sha, logs | host `/mnt/storage/dlesieur/osionos-beta/` (`/home` is full) |
| `osionos-beta-app` (develop build), `osionos-beta-edge` (nginx) | host, compose project `osionos-beta`, ports 127.0.0.1:3010/3011 |
| Timer | host `~/.config/systemd/user/osionos-beta.{service,timer}` |
| Tailnet exposure | VM baas: `tailscale serve --bg --https=8444 http://10.0.2.2:3010`, `--https=10001 http://10.0.2.2:3011` (no Funnel) |
| VM wall | host `/mnt/storage/virtual_machines/baas/wall` = `3001 8787 4000 3010 3011` |

`build.env` holds PUBLIC_SITE_ORIGIN, PUBLIC_MAIL_ORIGIN, PUBLIC_CALENDAR_ORIGIN (from `.env.public`)
and production's GRAPH_RENDER_SHA; no secret.

## Operate

- Logs: `journalctl --user -u osionos-beta -n 50` (host). Force a rebuild: `update.sh --force`.
- Kill switch (B10, rehearsed 2026-11-01): on the VM `tailscale serve --https=8444 off && tailscale serve --https=10001 off`,
  on the host `BETA_SHA=$(cat deployed) docker compose -f compose.yml down`.

## What it does not do

- Develop's bridge changes are not in the beta: it uses production's bridge.
- Sign-in emails and OAuth redirects land on production (:8443).
- Cookies are shared with production (same host): a develop XSS reaches production sessions.
