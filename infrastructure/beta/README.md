# osionos develop beta (ADR 0040)

https://baas-beta.tail10f2ea.ts.net/ (public, Tailscale Funnel) serves osionos `origin/develop`, rebuilt by a
systemd user timer within ~3 minutes of a push, against production's bridge and data. Its bridge
is https://baas-beta.tail10f2ea.ts.net:10000 (production's, behind the beta edge).
Conditions B1–B12: `docs/ops/beta-develop-verdict-2026-11-01.md`.

## Where it runs

| Piece | Where |
|---|---|
| Checkout, `build.env`, `deployed` sha, logs | host `/mnt/storage/dlesieur/osionos-beta/` (`/home` is full) |
| `osionos-beta-app` (develop build), `osionos-beta-edge` (nginx) | host, compose project `osionos-beta`, ports 127.0.0.1:3010/3011 |
| `osionos-beta-ts`: its own tailnet node `baas-beta`, Funnel on :443 and :10000 | host, same project; `ts-serve.json` serves :443 → edge :3010, :10000 → edge :3011; state in `ts-state/` |
| Timer | host `~/.config/systemd/user/osionos-beta.{service,timer}` |

`build.env` holds PUBLIC_SITE_ORIGIN, PUBLIC_MAIL_ORIGIN, PUBLIC_CALENDAR_ORIGIN (from `.env.public`)
and production's GRAPH_RENDER_SHA; no secret. `ts-authkey` was read once to join the tailnet;
the node stays logged in from `ts-state/`.

## Public, by the owner's decision (2026-11-01)

ADR 0040's B4 kept the beta tailnet-only. The owner made it public: "put it public, it's best for my
colleague … I accept the risks, all the data are fake anyway." The edge still admits only the beta's
own origin (B1/B2). Anyone on the internet can now load develop's code, and sign in against
production's bridge and data. To make it tailnet-only again, remove `AllowFunnel` from
`ts-serve.json` and recreate `osionos-beta-ts`.

## Sign-in

The beta is built with `VITE_AUTH_MODE=portal`: it shows its own sign-in and logs in at the bridge
with the production accounts. Prismatica's handoff only ever targets production (:8443).

## Operate

- Logs: `journalctl --user -u osionos-beta -n 50` (host). Force a rebuild: `update.sh --force`.
- Kill switch (B10): on the host `BETA_SHA=$(cat deployed) docker compose -f compose.yml down`
  (the tailnet node goes with it).
- A browser on a machine that routes through Tor (this laptop's `global-proxy`) must send the
  tailnet direct; invisibility-cloak's `global-proxy` does so since `324e40e`.

## What it does not do

- Develop's bridge changes are not in the beta: it uses production's bridge.
- Sign-in emails and OAuth redirects land on production (:8443).
- Realtime (`/realtime/v1/ws`) answers 400 "Connection header did not include 'upgrade'", as
  production does (2026-11-01): live updates need a reload.
- A computer's osionos-node opens a terminal for the beta only when started with
  `--app-origin https://baas-beta.tail10f2ea.ts.net`; that lets develop's code drive that shell.
