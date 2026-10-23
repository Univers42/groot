# 0002. Import groot's prod seed set into the baas VM through grobase's import pipeline

- Status: accepted with conditions (the apply is still to be run)
- Date: 2026-10-15
- Deciders: devil (risk ruling of 2026-10-15). The operator who runs the apply
  lives with it.

## Context

- The seed set in `./secrets` is the only authenticated one: it matches today's
  SHA256SUMS. `MANIFEST.json` `created_utc` is 2026-09-19T13:19:52Z. A newer run
  in key epoch 1 is not authenticated (ADR 0001).
- grobase 8b9321a6 ships the import pipeline: pack, rebind, push, apply, rollback
  (`apps/grobase/wiki/operations/data-import.md`). It ran on a VM on 2026-10-11
  with counts rc=0.
- `apply` snapshots each engine volume while the engines are stopped. It restarts
  the containers it recorded by their id and never runs `make up`
  (`apps/grobase/scripts/ops/grobase-import-apply.sh:149-157,251-262`).
- `make vault-restore` ends in `make up EDITION=devlean`. That would rebuild a
  different stack than the one the VM runs.
- Mount rows are sealed under the source `VAULT_ENC_KEY`. A key that does not
  open a row leaves the row byte for byte unchanged, because AES-GCM
  authentication fails (`apps/grobase/src/control-plane/internal/mountrebind/row.go:113-117`).
- Two timers on the VM interact with a stopped stack:
  - a daily cleanup prunes stopped containers older than 24 h;
  - an hourly backup dumps every running engine.
- Unknown when this was written:
  - which source env file holds the key that sealed the 13 mount rows;
  - whether rollback works on a live stack: it has only been tested against a
    docker stub (gate m226).

## Decision

The import runs through grobase's pipeline with `--target-ssh`. The rebind runs
first. A mount row is resealed for the VM when the source key opens it.

Three rows (website, gourmand, vault42, all created 2026-06-23) open under
neither candidate key. They are carried byte-identical, which is allowed
because the source could not open them either. The proof: the newest row opens
under the same key, and the Encryptor holds exactly one master key with no
fallback (`apps/grobase/src/control-plane/internal/adapterregistry/crypto.go:55`).

The apply runs inside the VM, inside a window that avoids both timers. Any
failure that leaves the stack down is rolled back the same night.

## Alternatives considered

- **`make vault-restore` in the VM**: it takes no volume snapshot. It recreates
  the stack with `EDITION=devlean` and runs `_rm-stale`, which loses the VM's
  overlay split.
- **The newer, unauthenticated epoch-1 run**: replaying SQL as the postgres
  superuser can execute code (`COPY … FROM PROGRAM`). Only bytes that match
  SHA256SUMS may be replayed.
- **Skip the rebind**: the restored tenants' mounts would all fail to open on the
  VM. The data would be there, but no app could reach it.

## Consequences

- Data created in prod after 2026-09-19 is not on the VM. Restored users have to
  log in again, because the JWT secret differs.
- The VM's earlier test user, tenants and keys are replaced. They exist only in
  the apply snapshot, which `/var/tmp` cleanup deletes after 30 days.
- sqlite and dynamodb mounts come back empty: their data was not captured.
- The full conditions and the exit-code protocol live in the operator's private
  verdict file, kept outside this repository.
