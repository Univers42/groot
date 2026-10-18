# Root wrappers around grobase's verify, scan and codegen targets are out of scope

- Decided: 2026-10-18 · by devil and the user (Q2 of the root make prune, ADR 0016)
- Holds while: `apps/grobase/Makefile` keeps its own `verify-%`, `verify-all` and `test-scan`
  targets.

## The concept

Keep `baas-verify-m1..m10`, `baas-verify-all`, `verify-*`, `baas-security-scan`, `baas-zap`,
`baas-security-audit`, `baas-compliance-*` and `baas-codegen` in the root make system, each a thin
wrapper over a script under `apps/grobase/scripts`, so they can be run from the groot checkout.

## Why not

- grobase owns those gates: `orchestrators/makes/40-tests.mk:60` defines `verify-%` and `:65`
  `verify-all`; `orchestrators/makes/100-test.mk:117` defines `test-scan`. A second entry point
  in groot is a second copy to keep in step with a submodule that moves on its own.
- The same module held `baas-down` and `baas-down-lean`, which ran `down -v` on project
  `mini-baas` (the live backend's data volumes) with no confirmation. Keeping the wrappers meant
  keeping a way to destroy the backend from a name that does not say so.
- Thirty targets in one module with no caller in the tree (checked by grep, 2026-10-18).

Use `make -C apps/grobase verify-m18`, `make -C apps/grobase verify-all`,
`make -C apps/grobase test-scan` instead.

## Prior requests

- 2026-10-18 (root make prune plan): proposed as "keep, document", ruled delete by the user (Q2).

## Reopen when

- grobase's Makefile loses `verify-%` or `test-scan`, so that groot would be the only place
  the gate can be run from; or
- a groot workflow needs a gate that grobase does not expose as a target.
