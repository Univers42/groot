# One SSRF allowlist shared by push and webhooks is out of scope

- Decided: 2026-11-24 · by devil (grobase webhook SSRF ruling, WS9)
- Holds while: an allowlist entry opens every port of the named host to every tenant of the feature that reads it

## The concept

Have webhooks read `PUSH_SSRF_ALLOW_HOSTS`, or one new shared variable, so that a single
operator list allows in-cluster receivers for both push and webhooks.

## Why not

- An entry is a whole host, every port, for every tenant of that feature. The push guard documents
  this itself (`push/ssrf.go:79-86`, grobase 5cfcae06). A shared list means that a sink added
  for one feature silently opens the same host to the other.
- The two features have different callers and different header control. Webhook tenants set
  arbitrary headers (`webhooks/attempt_deliver.go:131`); push does not. An allowlisted internal
  host is a worse target from webhooks.
- The cost of keeping them separate is one constructor argument in the shared `internal/egress`
  package.

## Prior requests

- 2026-11-24 (webhook SSRF fix plan): "a `WEBHOOK_SSRF_ALLOW_HOSTS` allowlist (or a shared one)".

## Reopen when

An allowlist entry can be scoped to a port and a tenant. At that point an entry stops widening
anything beyond the one sink.
