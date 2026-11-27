# DRAFT: grobase webhook delivery goes through one shared egress guard, with no redirects and no remote signal on refusal

- Status: draft, untracked. Ruled by devil 2026-11-24: PROCEED-WITH-CONDITIONS, WS1–WS12.
- Full ruling: `/mnt/storage/dlesieur/scratch/grobase-webhook-ssrf/RULING.md`.
- Code read: grobase `origin/main` 5cfcae06.

## Context

- **The client.** The webhook delivery client is a bare `http.Client` (`webhooks/delivery.go:65`).
  It has no dial control and honours proxy env, and it follows redirects.
- **The checks.**
  - Create checks the scheme only (`webhooks/models.go:60-68`).
  - PATCH checks nothing beyond the DB `CHECK (url ~ '^https?://')` (`service_crud.go:61-78`,
    `031_webhooks.sql:21`).
- **What an attacker reads back.** `last_error` stores the raw Go error (`attempt_record.go:40`)
  and the deliveries route returns it. That exposes:
  - refused vs timeout
  - the first line of a non-HTTP banner
  - the HTTP status code
- **Request control.** Tenant headers override everything but Host (`attempt_deliver.go:131`).
- **Who can create a webhook.**
  - Through Kong, only the baas-admin consumer: `key-auth` + `ip-restriction` + ACL. The live
    config has 1 ACL entry (`kong.yml:616-632`).
  - The dispatcher's port 3025 has no auth (`handler.go:39` stores `serviceToken` and never
    reads it; `httpauth.go:49`). It is reachable from 34 containers on `mini-baas_mini-baas` and
    VM loopback.
- **Live state, read-only, 2026-11-24.**
  - 0 webhook subscriptions and 0 deliveries.
  - Kong is DB-less, with the admin API on all interfaces.
  - `PUSH_ENABLED`, `SSO_ENABLED` and `TENANT_TELEMETRY_EXPORT_ENABLED` are unset.
- **The push guard** (`push/ssrf.go`, `push/dial.go`, `push/dispatch.go:74-77`) is reviewed, with
  two defects:
  - The dial control passes an unparsable address. `net.ParseIP("fe80::1%eth0") == nil` was
    proved at `dial.go:33`.
  - Its 400 echoes the resolved internal IP (`ssrf.go:72`, `handler_send.go:56`).
  - It also misses 0.0.0.0/8.
- **The same hole exists, off live**, in SSO `token_url` and `jwks_url`
  (`sso/token_exchange.go:93`, `sso/jwks.go:59`) and in the telemetry export sink
  (`telemetryexport.go:119`).
- **Already guarded:** Rust automations (`automations.rs:427`) and query-router automations
  (`automations.service.ts:220-277`). The query-router's rebinding pin is off live.
- Unknown when this was written:
  - whether the event payload can be shaped into a Kong `/config` body
  - the peer IP Kong sees for internet ingress
  - IPv6 egress on the VM
  - Node services other than query-router (not swept)

## Decision

- **One package, `internal/egress`, holds the guard.** It is tested alone and used by both push
  and webhooks. It contains:
  - the IP classifier, with 0.0.0.0/8 added
  - fail-closed target resolution
  - dial controls that refuse unparsable addresses
  - a proxy-free transport
- **Webhooks check the target on create and PATCH (400), and the dial control guards every
  connection.**
  - Redirects are refused.
  - A refusal marks the delivery `dead`, with a NULL status and a constant error.
  - Callers never see a resolved IP.
- `WEBHOOK_SSRF_ALLOW_HOSTS` is separate from push's allowlist and empty by default.

## Alternatives considered

- **Copy the push guard into webhooks.** Two classifiers drift. The false cross-references at
  `push/ssrf.go:23` and `dispatch.go:31` show they already have.
- **Re-guard each redirect hop.** Go forwards custom headers and the 307/308 body to the next host,
  and no webhook receiver needs redirects. The Rust and TS paths already refuse them
  (`automations.rs:172`, `automations.service.ts:235`).
- **A migration that marks private-target subscriptions dead.** There are 0 rows live, and the
  per-delivery dead record covers other deployments.
- **One shared allowlist.** Rejected in `.out-of-scope/egress-shared-allowlist.md`.

## Consequences

The conditions WS1–WS12 are acceptance criteria. The builder meets them, and they are listed in
the ruling.

- **WS1–WS2.** The shared package is tested on its own. Push keeps byte parity except for WS3
  and WS5.
- **WS3–WS4.** The dial control fails closed. The classifier blocks 0.0.0.0/8 and has table tests
  for mapped, NAT64, 6to4 and numeric-host forms.
- **WS5.** The refusal text is constant, for push too.
- **WS6–WS8.**
  - The create and PATCH guard returns 400.
  - Redirects are refused.
  - A refusal is recorded as dead, with no status code and a constant error.
- **WS9.** The webhook allowlist is separate, and metadata addresses stay refused.
- **WS10.** Four false comments are made true, and the guard gets a `Caveat:`.
- **WS11.** Rollout:
  - re-run the census before deploy
  - record the image digest and write the rollback script first
  - deploy the dispatcher only
  - run the probe with go-ahead, then clean up
- **WS12.** Gates: lint and `-race`, plus six named mutants killed. Four follow-up issues:
  1. the unauthenticated port 3025, which becomes a cross-tenant exfiltration path once
     egress is public-only
  2. SSO and telemetry adopt the egress package before their flags are turned on
  3. the query-router IP pin
  4. the Kong admin listener

- **What it costs.** The shared classifier becomes a single point of failure for two egress
  paths, so its tests and mutants are the load-bearing part.
- **Reverse it when** an in-cluster webhook receiver becomes a product need. Add an allowlist
  entry; never widen the classifier.
