# mini-BaaS Security Audit (2026-06-11)

A full sweep of the three planes (Rust data / Go control / TS application) — what
was found, what was repaired this session, what was verified safe, what remains,
and proactive hardening to consider next. Severities: **HIGH** (exploitable in a
realistic multi-tenant cloud), **MED** (hardening / depends on mode), **LOW**.

## Repaired this session

| # | Finding | Sev | Fix | Commit |
|---|---|---|---|---|
| 1 | **MSSQL `trust_cert()` unconditional** — accepted ANY server cert, *even under `SECURITY_MODE=max`* (MITM) | HIGH | `apply_mssql_tls`: verify by default; insecure only via `DATA_PLANE_TLS_INSECURE=1`, refused under max; CA pin via `DATA_PLANE_TLS_CA_FILE` | `17a6146` |
| 2 | **HTTP engine SSRF** — any `http(s)` mount dialed, no internal-address check → `169.254.169.254` (cloud metadata → creds), `127.0.0.1`, RFC-1918 | HIGH | `guard_and_resolve`: reject loopback/private/link-local/CGNAT/ULA + metadata hostnames; **pin** the client to validated public IPs (defeats DNS rebinding) | `10f8150` |
| 3 | **Service-token compared with `==`/`!=`** (timing side-channel) at 4 Go sites | MED | `shared.SecureCompare` (`crypto/subtle`) | `17a6146` |
| 4 | **mongo/redis cert-bypass DSN params** accepted under max (`tlsInsecure`, `rediss …#insecure`) | MED | `tls::reject_insecure_tls` refuses them under max | `17a6146` |
| 5 | **`/data/v1/{schema,ddl,graph}` skipped the per-tenant rate limiter** (only `/query` had it) — unthrottled DDL/graph DoS | MED | `bypass_ratelimit` wired into all three | `5416359` |
| 6 | **Graph BFS had no total-node cap** (depth×fanout unbounded) | MED | `MAX_GRAPH_NODES = 5000` DoS bound | `5416359` |

## Supply-chain scan (dependency CVEs) — `make audit-deps`

Ran `cargo audit` (Rust) + `govulncheck` (Go, reachability-based) on 2026-06-11.

**Go control plane — FIXED, now `0 vulnerabilities` (`b7339b4`):**
- ~10 Go **stdlib** CVEs (`crypto/x509`, `crypto/tls`, `net/http`, `net/url`, `os`)
  at go1.23 → fixed by bumping the build toolchain **golang:1.23 → 1.25.11**
  (stdlib-only, no code change).
- `go-redis v9.7.0` → **v9.20.0** (last module advisory).

**Rust data plane — 4 transitive advisories, accepted-with-remediation:**
- `rustls-webpki 0.101.7` ×3 (name-constraint bypass + CRL panic) and `idna 0.2.3`
  (Punycode) come from **`mongodb 2.8.2`** (old `rustls 0.21` + `trust-dns`) and
  **`tiberius 0.12.3`**. My own TLS path uses the patched `rustls 0.23.40 /
  webpki 0.103.13`. These are **only reachable for EXTERNAL TLS/SRV mongo|mssql
  mounts** — the stack's own mongo is plaintext on the docker net. **Remediation:**
  bump mongodb → 3.x + tiberius (a driver-adapter change; not rushed onto the
  live adapters). Tracked + `--ignore`d in `audit-deps.sh` so a *new* vuln still
  fails the gate.
- Warnings (unsound/unmaintained, not active vulns): `lru` (via `mysql_async`),
  `rand 0.7.3`, `derivative`, `rustls-pemfile` — clear on the same driver bumps.

## Verified safe (checked, no change needed)

- **SQL/NoSQL injection** — every table/column identifier flows through
  `quote_ident`/`quote_mysql_ident` (allowlist `[A-Za-z0-9_]`, then quoted); all
  values are bound as parameters (`$n` / `?` / `@Pn`). No string-interpolation of
  user values into SQL.
- **`SET LOCAL search_path`** — the schema comes from `mount.tenant_schema()`,
  which sanitizes to `tenant_[a-z0-9_]` (so it can't carry quotes/`;`/`-`).
- **Request body size** — axum's default 2 MB Json limit bounds payloads.
- **API-key authorization** — Argon2id verify stays in Go (sole authority); the
  Rust bypass scope-gates every op (admin/read/write) and owner-stamps writes.
- **Realtime** — deny-by-default on empty namespaces (no all-access fallback under max).

## Open — recommended hardening (mostly `SECURITY_MODE=max` work)

| # | Finding | Sev | Recommendation |
|---|---|---|---|
| O1 | Internal service token is a **static shared secret** (plaintext header, no rotation-without-restart) | MED | mTLS between planes, or per-request HMAC (caller+timestamp+body digest). Decouple from `JWT_SECRET`. |
| O2 | JWT is **HS256 symmetric**, `GOTRUE_JWT_SECRET` shared for user auth + service-token derivation | MED | RS256/JWKS with `kid` rotation; verify-only public keys at the edges (6c) |
| O3 | `CorsLayer::permissive()` on the data plane | MED | The data plane must never be browser-reachable except via Kong; restrict CORS to configured origins. Low CSRF risk today (API-key, no cookies) |
| O4 | Postgres `sslmode=require` is accept-any **outside** max | MED | Recommend `SECURITY_MODE=max` for multi-tenant (upgrades `require`→verify); consider verify-default for non-loopback DSNs |
| O5 | **Vault not enforced** — DSNs may be inline-encrypted or in plaintext `DATA_PLANE_MOUNTS` | MED | Under max, require `credential_ref{provider:vault}`; forbid plaintext mounts in prod (6b) |
| O6 | adapter-registry **trusts `X-Baas-*` identity headers** on the private net | LOW | HMAC-sign the identity headers (the TS gateway used to) |
| O7 | DDL route is **tier-independent** (the `schema_ddl` mask isn't enforced on `/data/v1/schema/ddl`) | LOW | *By design* — every tier manages its own schema (prototyping needs it); the mask narrows data-op capabilities (aggregate/txn/batch). Documented, not a hole |
| O8 | Reads are **not audited** (only mutations + denials) | LOW | Optional max-mode "sensitive-read" audit on flagged resources |

## Other solutions — proactive defense-in-depth (beyond what was asked)

1. **mTLS service mesh** between planes (Rust↔Go↔TS) — kills O1+O6 at once; SPIFFE/SVID identities.
2. **Dynamic, short-lived DB credentials** via Vault's database secrets engine (creds expire in minutes; a leaked DSN is near-useless) — strict upgrade over static encrypted DSNs.
3. **Supply-chain scanning in CI** — add `cargo audit` + `cargo deny` (Rust) and `govulncheck` (Go) alongside the existing SEMGREP + `npm audit`; fail on known CVEs. Pin digests (already partially via `pin-digests.sh`).
4. **Container hardening** — distroless (already for some), `read_only: true` rootfs + `tmpfs` for scratch, `cap_drop: [ALL]`, `security_opt: [no-new-privileges]`, a seccomp profile. The data-plane-router (9 MB, single static binary) is an ideal candidate.
5. **Egress allowlist** for the whole stack (not just the SSRF guard) — default-deny outbound, allow only known upstreams; stops exfiltration even if an SSRF-adjacent bug slips through.
6. **Audit → SIEM + anomaly detection** — ship the `audit` tracing target to Loki/a SIEM and alert on spikes of cross-tenant 404s (probing), 401/403 bursts, or rate-limit hits — early-warning for credential stuffing / enumeration.
7. **RLS as defense-in-depth** — keep the owner-scoped predicates, but ALSO enable Postgres Row-Level Security policies on tenant tables, so a missing predicate can't leak rows (belt + suspenders). The `m23`/G5 validation-at-mount work is the hook.
8. **Per-key + per-IP layered limits** — Kong's per-IP limit (coarse outer shell) + the Rust per-tenant token bucket (inner) are in place; add a per-API-key limit and a global circuit breaker for abusive tenants.
9. **Secret rotation runbook + automation** — `make vault-rotate-approles` exists; schedule it, and rotate `JWT_SECRET`/`INTERNAL_SERVICE_TOKEN` on a cadence (needs O1/O2 to be rotation-without-restart).
10. **DAST / pentest pass + fuzzing** — fuzz the filter/DDL parsers (`cargo fuzz`) and the JSON envelopes; run a DAST scan against `/data/v1` and Kong.
11. **Backups encrypted + restore-tested** — encrypt volume backups at rest; periodically test restores (an untested backup is not a backup).
12. **Tenant resource quotas** — beyond rate (rps): cap rows-per-query, query timeout, pool size, and storage per tenant, so one tenant can't starve the shared engines.

## How to re-run the security gates

```bash
make baas-security-scan          # SEMGREP + npm audit (add cargo-audit/govulncheck — solution #3)
make verify-m30                  # (max) per-engine untrusted-cert rejection + constant-time token
make verify-m32                  # per-tier resource budgets (DoS-floor regression)
make verify-m33                  # basic tier: Node-free + scope-gate (write/ddl 403 for read-only)
make verify-m34                  # graph parity (incl. the new node-cap + rate-limit)
```
