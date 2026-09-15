# Bringing the stack up

> **Status:** Partial · 2026-09-15
> **Evidence:** targets and edition names read from the backend document; a clean clone plus
> `make all` is CI-proven per the repository README
> **To check:** which edition groot's `make all` actually raises — MAP.md says `migrate`, but
> `make editions` in grobase lists `lean query realtime analytics prod full` and `migrate` is
> not among them. Determines what is actually running when you think the stack is up.
> **Sources:** `apps/grobase/CLAUDE.md` §Running & building, §Editions · root `Makefile`

**Nothing installs on the host** — no node, npm, go or cargo. Everything runs through the root
`Makefile` or `docker compose`. If an instruction starts with `npm install`, it is wrong.

---

## The short version

```sh
make quickstart      # generate .env → up → health
make health          # is it actually serving?
make doctor          # diagnose a sick stack
make ps | logs       # what is running, what is it saying
```

A full build is minutes — grobase alone around nine. Plan for it.

---

## Shapes: editions, packages, planes

Fifteen compose **planes** exist and they do not all come up. An **edition** is a named set of
them (`make editions`): `lean · query · realtime · analytics · prod · full`. The default is
**`query`** — data, go, rust, adapter, background.

A **package** is a customer tier — `nano basic essential pro max` — growing by accumulation:
`basic` is go and rust; `essential` adds adapter and background; `pro` adds data, storage and
realtime; `max` adds analytics, observability, functions and engines.

Precedence when several are set: **profiles > package > edition**.

```sh
make up EDITION=full
make up PACKAGE=pro
```

---

## Two traps that cost an afternoon

**Realtime is not in the default edition.** Demonstrating live collaboration on `EDITION=query`
shows nothing, and the failure looks like a broken application rather than an absent plane. Use
`EDITION=realtime|prod|full` or `PACKAGE=pro`.

**Half a flag is a silent no-op.** Metering, quotas and per-tenant observability each need a
flag on *both* planes. Raise one and nothing happens — no error, no warning.
→ [02-flags](02-flags.md)

---

## Local mode needs no vault key

You do not need `~/.config/42ctl/` to bring the stack up locally — the vault key is for pulling
the shared secret tree. → [05-secrets](05-secrets.md)

---

## Product shapes in the binary

Separately, the data plane builds several products from one codebase via cargo features
(`crates/data-plane-server/Cargo.toml`):

```
default = ["engines-full", "control-pg", "ratelimit-redis"]
nano    = SQLite only, ~5 MB scratch image
one     = + OAuth/OIDC, argon2id, TOTP MFA, SMTP, file storage, admin UI at /_/
```

The normal build already carries all seven engines; `nano` and `one` are deliberate reductions,
not additions. → [platform/08-engines](../platform/08-engines.md)

---

## Verify gates are the unit of "done"

```sh
bash scripts/verify/run-gate-battery.sh --fast         # per-PR
bash scripts/verify/run-gate-battery.sh --enterprise   # nightly
```

→ [quality/01-gates](../quality/01-gates.md)

---

## When it comes up green but wrong

Start at [04-troubleshooting](04-troubleshooting.md). Usually the compose pull-fallback: 54
services fetch a published image instead of building your code.

---

See also: [02-flags](02-flags.md) · [03-deployment](03-deployment.md) ·
[platform/02-planes](../platform/02-planes.md)
