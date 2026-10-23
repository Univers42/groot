# Real mail from Titan

Every mail this product sends leaves through grobase: GoTrue, the orchestrator's email service
(`/email/v1/send`) and tenant-control's login code. The site's auth-gateway holds no SMTP
settings; it posts to `${PUBLIC_BAAS_URL}/email/v1/send` with the service key
([ADR 0006](../../docs/adr/0006-grobase-is-the-only-mail-sender-behind-a-service-only-email-route.md)).
By default all of it lands in Mailpit.

## Switch a machine to Titan

1. In `apps/grobase/.env.local` (git-ignored) set the two aliases. Single-quote the password,
   because `$` and `#` inside an unquoted or double-quoted value are interpreted:

   ```sh
   TITAN_EMAIL=noreply@example.org
   TITAN_PASSWORD='a$b#c'
   ```

2. Run `make env` in `apps/grobase`. It derives `SMTP_HOST`, `SMTP_PORT=465`, `SMTP_SECURE=true`,
   `SMTP_USER`, `SMTP_PASS` and `EMAIL_FROM` into `.env`. An explicit `SMTP_USER` or `SMTP_PASS`
   that differs from the alias stops it with exit 1, naming the keys and no values. How the
   derivation works, and its edge cases: grobase `docs/infrastructure/configuration.md`, "The Titan
   mail alias".
3. Recreate the services that read it. Do this only in the order the ADR sets (conditions 1 and 8-11
  ): Kong with the `/email/v1` acl live and the anonymous key proven refused **before**
   `.env.local` gains Titan. Once the env says Titan, any orchestrator recreate opens the relay if
   the acl is missing. Those baas steps are run by the user, not by an agent.

To go back, delete both alias lines, run `make env`, recreate the same services.

## The e2e mail guard

`tests/e2e/run.sh` refuses the `pr*` and `dm*` specs (they sign up users and mail them) unless
`scripts/lib/e2e-mail-guard.sh` proves, from what is running:

- the link relay does not point at a remote backend;
- each auth-gateway container has `PUBLIC_BAAS_URL` on the local Kong (`mini-baas-kong`);
- `mini-baas-gotrue` has `GOTRUE_SMTP_HOST` on Mailpit;
- `mini-baas-orchestrator` and `mini-baas-tenant-control`, when running, have `SMTP_HOST` on
  Mailpit (`mailpit`, `mini-baas-mailpit`, `localhost`, `127.0.0.1`).

So a machine with `TITAN_*` set skips those specs in a full run and gets exit 3 when one is named.
The refusal names the container and the key, never a value. Unset the aliases and recreate to
run them again.

## What this does not do

- It does not test the Titan credentials or open a connection; a wrong password shows up as a
  failed send in grobase's logs.
- The guard reads container environments, not mailboxes: a sender that relays to Titan under the
  name `mailpit` passes. A stopped `mini-baas-tenant-control` is not checked.
- It does not cover a grobase on another host: the link check refuses `ssh` and `direct` modes,
  and the specs then do not run.
- `make env` does not touch a deployed baas; Fly secrets and the baas `.env.local` are set by the
  user.
