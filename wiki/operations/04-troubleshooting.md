# Troubleshooting

> **Status:** Verified · 2026-09-15
> **Evidence:** the pull-fallback and the gateway chain are both handled explicitly in
> `deploy/fly/boot.sh`; flag gating is structural per the backend document
> **Sources:** `deploy/fly/boot.sh` · `apps/grobase/CLAUDE.md`
> **Deeper:** [archive/wiki-2026-09/troubleshoot/](../../archive/wiki-2026-09/troubleshoot/) —
> including the 914-line local CA runbook

Ordered by how often it is the answer. The first three account for most "it doesn't work".

---

## 1 · Your changes are not in the running container

**Symptom:** everything comes up green, the behaviour is the old behaviour, and your edits have
no effect anywhere.

**Cause:** 54 services carry `image: ghcr.io/univers42/grobase-<svc>:latest` above their `build:`
block. A plain `docker compose up` **fetches the published image instead of building your code**.
Production handles this explicitly — see `ensure_dynamodb_feature` in
[03-deployment](03-deployment.md).

**Fix:** `make build`, or `docker compose up -d --build <service>` for one. That second form is
also the fast path to rehearse for a live modification during the evaluation.

---

## 2 · A route returns 404 that should exist

**Cause:** in Go, gated routes are **not mounted** when the flag is unset — ~38 sites. Not a 403;
the endpoint genuinely does not exist.

**Fix:** check the flag before reading handler code, and check *both halves* for paired features.
→ [02-flags](02-flags.md)

---

## 3 · A feature is enabled and still does nothing

**Cause:** the master/sub pattern. Metering, quotas and per-tenant observability each need a
flag on both planes; raising one gives a **silent no-op**.

**Fix:** `METERING_ENABLED` **and** `DATA_PLANE_METERING`. Same for quotas and observability.

---

## 4 · The public door is down but the stack is "up"

**Symptom:** `kong` sits in `Created`, nothing answers on the public port, everything else looks
fine.

**Cause:** Mongo's healthcheck can exceed its 3s timeout on a cold reboot, stranding the
`realtime → kong` dependency chain. Mongo itself is serving.

**Fix:** force the chain up ignoring dependencies:

```sh
docker compose up -d --no-deps mongo-init && sleep 4 \
  && docker compose up -d --no-deps realtime && sleep 3 \
  && docker compose up -d --no-deps kong
```

---

## 5 · Nothing to demonstrate in the collaboration demo

**Cause:** realtime is not in the default `query` edition. The failure looks like a broken
application rather than an absent plane.

**Fix:** `EDITION=realtime|prod|full` or `PACKAGE=pro`. → [01-bring-up](01-bring-up.md)

---

## 6 · Browser warns about the certificate

Local HTTPS uses a locally generated CA that the host has to trust. The archived runbook
`troubleshoot/trust-ca-from-host.md` is 914 lines and covers every host case; start there rather
than improvising.

---

## 7 · Docker Hub rate limit

`docker/daemon_too_many_request.md` in the archive. Usually resolved by authenticating the
daemon rather than by waiting.

---

## The rule underneath all of this

**Silence is not success.** A green log or a passing check means nothing until you know the tool
looked at the right thing — three of the seven cases above are exactly that: green, healthy and
wrong. Prefer exit codes to a truncated tail, and read the script when a gate matters.
→ [quality/01-gates](../quality/01-gates.md)

---

See also: [01-bring-up](01-bring-up.md) · [02-flags](02-flags.md) ·
[03-deployment](03-deployment.md)
