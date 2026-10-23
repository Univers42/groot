# Public Prismatica site on b2b — Funnel :10000

Serves the site and its auth gateway to colleagues at `https://baas.tail10f2ea.ts.net:10000`
from the b2b VM, without Fly. Decision and risk conditions (PUB-1 to PUB-16): [ADR 0013](../../docs/adr/0013-serve-the-prismatica-site-from-b2b-on-funnel-10000.md).
Every step that writes on the VM is a command you run; nothing here runs it for you.

## What runs

| Piece | Where | Notes |
|---|---|---|
| `public-site` | project `prismatica-public` | nginx + static build. Publishes `127.0.0.1:10080` only. `/api/` goes to `mini-baas-waf:80`, `/api/auth` and `/api/newsletter` to the gateway |
| `public-auth-gateway` | same project | No published port. Joins `mini-baas_mini-baas` to call Kong with the service key |
| `public-redis` | same project | Its own redis, append-only volume, 64 MB cap. `mini-baas-redis` is never used |
| Funnel `:10000` | tailscaled on b2b | `tailscale funnel --https=10000 http://127.0.0.1:10080`. The `:443` entries are not touched |

Compose file: `infrastructure/compose/public-b2b.yml`. Scripts: `scripts/public-b2b/`.
There is no osionos-bridge, so the osionos hand-off answers 503.

## Before you start

- The opposite-osiris commit you build holds the gateway changes for `AUTH_SIGNUP_ALLOWLIST`,
  `AUTH_MAIL_DAILY_CAP`, `AUTH_LOGIN_EMAIL_OTP` and the approve link (`AUTH_LOGIN_APPROVE_LINK`).
  The image is tagged by that commit's sha, so build from the merged commit.
- Cloudflare Turnstile: a widget whose allowed hostnames include `baas.tail10f2ea.ts.net`.
  You hold its site key (public) and secret key. Whether the widget allows that hostname is not
  checked by any script here.
- Titan's daily send cap (SGN-5). `AUTH_MAIL_DAILY_CAP` defaults to 200; set it lower in the
  environment of the deploy if the cap is lower.
- The anon grant on `public.users.email` is checked by `deploy.sh` (PUB-3) and stops the deploy
  when anon can read it.

## The order

Run from the groot checkout. `sudo` on the VM needs a terminal, hence `ssh -t`.

1. Create the VM env file. It asks for the Turnstile secret (hidden) and the allowlist
   (domains and exact addresses of your colleagues). It copies the service and anon keys out of
   `/opt/grobase/.env` without printing them and prints only key names with set/unset.

   ```sh
   ssh -t b2b "echo $(base64 -w0 scripts/public-b2b/env-init.sh) | base64 -d | bash"
   ```

2. Write the build inputs. The anon key is public by design (it ships in the bundle); the file is
   git-ignored.

   ```sh
   ssh b2b "grep '^PUBLIC_BAAS_ANON_KEY=' /opt/prismatica-public/.env" > .env.public-b2b
   printf 'PUBLIC_TURNSTILE_SITE_KEY=%s\n' '<your Turnstile site key>' >> .env.public-b2b
   ```

3. Build both images here, never on the VM (it has no docker0 bridge). The script prints the
   layers hash of each image and the PUB-7 greps.

   ```sh
   bash scripts/public-b2b/build-images.sh <path to the opposite-osiris worktree>
   ```

4. Deploy, with the 12-character sha the build printed. It ships the images, brings the project
   up, checks it on loopback, opens the funnel, and proves what did not move: the serve diff adds
   only the `:10000` keys, the WAF container Id and start time are unchanged, the `mini-baas`
   container set is unchanged. On a failure after the first write it prints the rollback line.

   ```sh
   bash scripts/public-b2b/deploy.sh <sha12>
   ```

   If your network blocks `:10000`, the public-URL checks fail from here although the funnel is
   up: rerun the whole step with `PUBLIC_CHECK_FROM=vm`, or check from a phone.

5. The PUB-12 phone run below. Do not send the link before it passes.

## PUB-12 end-to-end check, from a phone on cellular

You run all of it; the scripts cannot receive mail.

- [ ] Open `https://baas.tail10f2ea.ts.net:10000`. The page loads and the Turnstile widget renders.
- [ ] Sign up with an allowlisted address. The confirm mail arrives from `devfast@archicode.codes`;
      its link opens `:10000` and confirms the account.
- [ ] Sign up with an address that is not on the allowlist. The answer looks the same, and no mail
      arrives.
- [ ] Sign in. One mail arrives with the approve link; type the 2-digit number shown on the phone.
- [ ] Sign in with a wrong number. The sign-in is revoked.
- [ ] Subscribe to the newsletter with an allowlisted address, then confirm.
- [ ] PUB-1: read the audit row of your sign-in (SQL below). `ip_address` is the phone's public
      address. Sign in again with a header `X-Forwarded-For: 1.2.3.4`: the recorded address is
      still the phone's. A docker address (`172.x.0.1`) means stop and roll back.
- [ ] PUB-2 (optional): `POST /api/rest/v1/rpc/gdpr_submit_request` with the anon key does not
      answer 403 from the WAF. `deploy.sh` does not probe it.

```sql
SELECT created_at, event_type, email, ip_address
  FROM public.auth_audit_events
 WHERE created_at >= now() - interval '30 minutes'
 ORDER BY created_at;
```

## What colleagues get

- One URL: `https://baas.tail10f2ea.ts.net:10000`. They need no VPN and no Tailscale install.
- `:10000` is a non-standard port. Some school and corporate networks block it; the fallback is
  their phone's cellular data (PUB-16).
- Every client behind one NAT shares the per-IP buckets (login 8 per minute, register 12 per
  minute). A room of people on one wifi hits 429s together (PUB-16).
- Only addresses on the allowlist can sign up or subscribe. Others get the same answer and no mail.
- The osionos app is not behind this URL.

## Rollback

```sh
bash scripts/public-b2b/rollback.sh
```

It turns `:10000` off, checks the serve config equals the one `deploy.sh` saved (so both `:443`
hosts are as they were), and runs `docker compose -p prismatica-public down` without `-v`.
It never runs `tailscale serve reset`.

It does not undo what visitors did. Accounts, `public.users` rows, newsletter opt-ins and sent
mail stay in grobase prod. The script prints the SQL that lists `auth_audit_events` since the
deploy; deleting those rows is by hand. The redis volume stays until you remove it.

## Files on the VM

| Path | What |
|---|---|
| `/opt/prismatica-public/.env` | Secrets, mode 600. Never copied off the VM |
| `/opt/prismatica-public/images.env` | Image tags and the loopback port; no secret |
| `/opt/prismatica-public/public-b2b.yml` | The compose file `deploy.sh` copied |
| `/opt/prismatica-public/serve-{before,after,rollback}-<UTC stamp>.json` | `tailscale serve status --json` at each stage |

## Not covered

- tailscaled's own `X-Forwarded-For` behaviour was reasoned from source, not measured. The PUB-1
  phone check is the measurement.
- A real-time phishing proxy defeats number matching and codes alike; only WebAuthn stops it.
- The static `robots.txt` and the docs pages still name `localhost:4322`; the HTML pages carry the
  Funnel URL. Neither affects sign-in.
