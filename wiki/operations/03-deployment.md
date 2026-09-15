# Deployment

> **Status:** Verified · 2026-09-15
> **Evidence:** `deploy/fly/boot.sh` read directly; the service boundary is declared binding by
> a repository rule
> **Sources:** `deploy/fly/boot.sh` · `apps/grobase/CLAUDE.md` §Going to production

The whole backend runs on **a single fly.io Machine**, Docker inside Docker. Frontends are
stateless on Vercel. **grobase owns all state** — database, auth, OTP, realtime, files. That
boundary is declared **binding** by a repository rule: a frontend that starts holding state has
broken the architecture, not bent it.

---

## What happens on boot

`boot.sh` runs this sequence on every start:

1. start `dockerd` on the fly volume
2. clone or fast-forward `main`
3. assemble `.env` — secrets restored from the volume, local overrides written
4. wait for GoTrue to create `auth.users`, then apply SQL migrations (once; marker file)
5. bring up ~22 curated services, Kong last
6. ensure the DynamoDB feature is compiled in
7. provision the registered contracts (once; marker file)
8. tail the logs of the five services worth watching

Two marker files make it idempotent (`.migrated`, `.provisioned`); a one-shot `RESET` token
forces `compose down -v`. Contracts provisioned at boot: **`website` and `vault42`**.
→ [platform/06-contracts](../platform/06-contracts.md)

---

## Two functions that are operational scar tissue

These are worth reading because they teach how the system actually behaves.

```bash
ensure_dynamodb_feature() {
  # the ghcr pull-fallback fetches an image compiled WITHOUT dynamodb;
  # detect it via /v1/capabilities and rebuild with the feature (BuildKit-cached).
  docker build --build-arg DATA_PLANE_FEATURES="--features dynamodb" ...
}
```

That is the compose pull-fallback handled in production code. → [04-troubleshooting](04-troubleshooting.md)

```bash
ensure_gateway() {
  # mongo's healthcheck can exceed its 3s timeout on a cold reboot, stranding the
  # realtime→kong depends_on chain ("kong Created", public door down).
  # force the chain with --no-deps so the gateway recovers unattended.
  $DC up -d --no-deps mongo-init ; sleep 4 ; ... realtime ; ... kong
}
```

A healthcheck timeout on one service taking the public door down is exactly the kind of failure
you only find in production.

---

## Mail

SMTP credentials come from fly secrets. With `SMTP_PASS` set, OTP and transactional mail reach a
**real inbox**; without it the stack falls back to the internal Mailpit sink. For a
demonstration, a full sign-up with a real confirmation email beats any screenshot.

---

## What is exposed

Kong is the only published port. Everything else stays on the inner Docker network. CORS origins
and `IDENTITY_HEADER_MODE=strict` are pinned to the public host at boot.
→ [security/04-network](../security/04-network.md)

---

## Why this matters for the evaluation

**There is a live, public system.** Multi-user access, HTTPS, the public API, email OTP to a
real inbox, and two non-merging databases proving per-user isolation can all be shown on the
running deployment rather than on a laptop.

Have **both paths ready**: the live one removes the risk of the stack failing that morning, the
local one the risk of the network failing. Run `make health` against the public instance the day
before — it is a public system, so a break the night before breaks in front of everyone.

---

## Frontends

Stateless, on Vercel, reaching the backend **same-origin through rewrites** — with realtime's
`wss://` as the single documented exception.
→ [platform/05-realtime](../platform/05-realtime.md)

---

See also: [01-bring-up](01-bring-up.md) · [02-flags](02-flags.md) ·
[04-troubleshooting](04-troubleshooting.md)
