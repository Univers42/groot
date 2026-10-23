# 0003. Link groot's frontends to the imported grobase VM over ssh, converging step by step

- Status: accepted with conditions (the link is still to be run)
- Date: 2026-10-15
- Deciders: devil (risk ruling of 2026-10-15). The operator who runs the link
  and the converge steps lives with it.

## Context

- Only ssh mode fetches the target's own `.env`. Direct mode derives the keys
  from whatever `./.env.grobase-remote` or `apps/grobase/.env` already holds
  (`scripts/grobase-link.sh:237`), which here is the previous deployment's.
- Direct mode refuses the model migrations (`scripts/grobase-link.sh:271`). It
  relays no realtime port (`scripts/lib/grobase-link-target.sh:88-92`). Its
  live-data step exits 0 "skipping" when tenant-control is not on this daemon
  (`scripts/ensure-live-data-access.sh:130`).
- The link's ssh master clears the alias's forwards (`scripts/grobase-link.sh:92`).
  docker's ssh transport, used by the three converge steps, does not.
- The migrations are idempotent-shaped. psql runs each file without a single
  transaction (`scripts/apply-models-migrations.sh:137-139`). Two files drop and
  re-add a CHECK in separate statements (`models/osionos-code-surface-migration.sql:16-19`,
  `models/osionos-social-migration.sql:81-92`).
- `models/realtime-cdc-off-migration.sql` (2026-10-14) drops the realtime row
  triggers on every public table of the target's postgres. That covers every
  tenant on it.
- If the app's API key does not verify, `ensure-live-data-access.sh` issues a new
  key. It then re-stamps every `api-key:*` owner in five demo databases onto that
  key, in the same run.
- The shared-demo marker dates from 93e5a8d7 (2026-10-12). The imported data's
  cutoff is 2026-09-19.
- `make link` rewrites `./.env.grobase-remote` and `./.env.local`. A team push
  publishes both as private entries (`scripts/vault42-team.sh:72-75`). The push
  guard does not inspect them.
- Unknown when this was written: whether the restored app key verifies, and
  whether the restored rows satisfy the current CHECK lists. The read-only
  checks named under Decision measure both.

## Decision

The frontends reach the imported grobase in ssh mode. Nothing on the link runs
before the import's acceptance is recorded. After `make link`, two read-only
checks run first: `models-check` and `ensure-live-data-access.sh --check`. The
converge steps then run one at a time: migrations, demo login, live data, start.
A failure stops the sequence. The demo password is reset only by the operator,
with no force flag.

## Alternatives considered

- **Direct mode through the public URL**: it derives every key from the previous
  deployment's file, so every call gets 401. It also cannot run migrations or
  reach tenant-control, and its live-data step reports success without running.
- **`make link-frontends-up` as one command**: it issues a new key and re-stamps
  the demo rows in the same run when the key does not verify. That write cannot
  be undone. It also writes into data the import had not yet accepted.
- **Copy the target's `.env` in by hand and stay direct**: this puts the same
  secrets in the same file, with no realtime and no database access.

## Consequences

- The local env files can be restored from a checksummed backup taken before the
  link. The demo hash, the re-stamped owners and the dropped triggers cannot be
  restored that way. Their way back is the import pack or the VM snapshot, so
  both are kept until the link is accepted.
- No prod push from this checkout while its env files hold the new target's
  secrets, unless the operator decides that target is prod. Otherwise the prod
  vault head would carry them. ADR 0001's republish checks
  `.env.grobase-remote` against the backup.
- Realtime row broadcasts are off for every tenant on the target. Any restart of
  the target's stack re-arms them until the migrations run again.
- The full conditions are in the operator's private verdict file, kept outside
  this repository.
- Addendum, 2026-10-15: the empty sqlite/dynamodb mounts were refilled by running
  grobase `scripts/seed/osionos-extra-engines.sh` in the target. The mssql reload
  was accepted because the generator's 1635 rows equal the restored set. Its edge
  step shares one seeded PRNG across engine kinds (`extra-engines-gen.py:239-300`).
  If a different set of engines is wired, every edge target shifts and spurious
  edges are inserted. So the run was gated on all three engines being wired, and
  on a backup of `commerce.public.edges`, with exactly 250 edges per relation
  afterwards.
