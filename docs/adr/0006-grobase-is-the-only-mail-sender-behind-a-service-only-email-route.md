# 0006. grobase is the only mail sender, and /email/v1 is service-key only

- Status: accepted with conditions (nothing built or deployed yet)
- Date: 2026-10-16
- Deciders: the user (mail lives only in grobase, ruled 2026-10-16); devil (risk ruling of 2026-10-16).
  The user runs every baas and Fly action.

## Context

- Kong route `email-routes` has key-auth, jwt(anonymous), size and rate limits, and no acl
  (`apps/grobase/infra/docker/services/kong/conf/kong.yml:825-852`). Only `service_role` is in
  `baas-admin` (`kong.yml:12-20`); `anon` has no group (`kong.yml:9-11`).
- The anon key reached emailsvc on baas: `POST /email/v1/send {}` returned emailsvc's 400 (measured
  2026-10-16, plan evidence; `emailsvc/handler.go:43`).
- emailsvc picks implicit TLS only from `SMTP_SECURE=="true"` (`emailsvc/emailsvc.go:57`,
  `smtp.go:50-53`); Titan is on :465.
- WAF rule 10130 does not list `/email/v1` (`infra/docker/services/waf/conf/exclusions.conf:143-153`),
  so the Funnel path reaches it, and Kong sees Funnel clients as loopback.
- `docker compose up -d kong` also recreates `gotrue` (`orchestrators/compose/base/gateway.yml`
  depends_on), not the orchestrator.
- m49 probes with the anon key and passes on any non-5xx (`scripts/verify/m49-orchestrator-cutover.sh:53-81`),
  so after the acl it would pass on a 403 and prove nothing.
- The site gateway's email-domain allowlist is derived from SMTP config: sender domain and the local
  test domains (`opposite-osiris/scripts/auth-gateway.mjs:159-178`, used at `:182`).
- Unknown: whether the orchestrator image on baas is built from source or pulled from ghcr :latest.

## Decision

`/email/v1` carries `acl allow [baas-admin]`, so only the service_role key sends. emailsvc and GoTrue
read one set of SMTP keys, and port 465 implies implicit TLS in both. The site gateway holds no SMTP
config; it sends through `/email/v1` with the service key it already holds (`auth-gateway.mjs:53`).

## Alternatives considered

- **Leave the route open, rely on rate limits**: 200/h per IP from Funnel/loopback is a shared bucket, and
  any anon-key holder sends arbitrary HTML as devfast@archicode.codes.
- **ip-restriction on the route**: one proxy hop from useless, since Funnel clients look like loopback
  (`kong.yml:15-18`).
- **Keep the gateway's own SMTP sender**: refused by the user's ruling, and it keeps a second copy of the
  Titan password outside grobase.

## Consequences

Conditions of the ruling (acceptance criteria):

1. Order on baas: Kong with the acl live and anon proven 403 by the acl **before** `.env.local` is edited.
   Once the env says Titan, any orchestrator recreate opens the relay if the acl is missing.
2. The gateway ships only after a service-key send through its real `BAAS_URL` lands at Titan
   (user-run). Until then emailsvc on mailpit returns 2xx, the gateway reports success, and no mail arrives.
3. m206 probes the email route by GET or `{}` only, never a valid payload. Mutation: removing the acl fails it.
4. m49 takes the key per probe; the email probe uses service + `{}` and asserts 400, not "not 5xx".
5. The gateway keeps `example.test`/`mini-baas.local` and the sender-domain fast path from an explicit
   setting, so local e2e registrations do not start failing the MX check.
6. The gateway treats 429/403/5xx from `/email/v1` as failure, with a Caveat on the global 10/min quota.
   No log line carries the apikey.
7. The port-465 rule ships with a unit test and a mutation check; until baas runs the rebuilt image,
   `SMTP_SECURE=true` in `.env.local` covers it.

Reverse by dropping the acl and restoring the gateway's SMTP config. Mail already sent cannot be recalled.
