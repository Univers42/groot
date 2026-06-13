# A6 Security Residuals — Human-Supervised Runbooks

> Companion to [`security-audit-asvs.md`](security-audit-asvs.md) §3 (the 7 open residuals) and the A6
> roadmap row. Authored 2026-06-13 from a read-only research fan-out that ranked all 7 residuals by
> **value × autonomous-safety**.
>
> **Two residuals were closed autonomously** (additive, flag-gated **OFF** = byte-parity baseline,
> provable by isolated scratch gates): **G-ReadAudit** (`DATA_PLANE_AUDIT_READS`, gate `m72`) and
> **G-QoS slice A** rows-per-query cap (`max_rows`, gate `m73`). See [[../.claude/memory/decisions.md]].
>
> **The five below are deferred to human-supervised waves** — each is **cross-repo** and/or **touches
> the live login flow** or would **re-network the shared stack**, which kernel rule #9 forbids touching
> unsupervised. Each runbook is *prove-on-an-isolated-scratch-scope first, flip the live thing last*.
> Run each with the security-review skill.

| Residual | ASVS value | Why deferred | Blast radius if rushed |
|---|---|---|---|
| **G-RS256** | MED | Cross-repo (vendored gotrue + Kong) + global login property | Partial flip 401s **every** authenticated request stack-wide |
| **G-Vault** | MED | New register contract + DB schema + data-plane resolve path | Wrong order locks max-tier tenants out of registering any mount |
| **G-Net** | MED | Value-bearing half re-networks ~50 live services | One wrong edge wedges inter-service DNS/comms |
| **G-Hdr** | LOW | Effective only when flipped on the live mount-resolution hot path | An unsigned caller → instant 401s, wedged live queries |
| **G-Rotate** | LOW | JWT half is cross-repo + touches live login | A bug is a stack-wide auth outage |

Priority order for the human waves: **G-RS256** (highest value, headline) → **G-Vault** → **G-Net (safe Helm half)** → **G-Hdr** → **G-Rotate (service-token half)**. The cross-repo/live-login halves of Net/Hdr/Rotate are lowest priority (LOW value, highest risk).

---

## G-RS256 — flip the JWT issuer to RS256/JWKS (the headline)

**Why it can't be flag-gated to byte-parity:** the issuer is a *global* property — GoTrue signs, Kong
validates (~21 jwt-plugin routes), and tenant-control all share `JWT_SECRET`/HS256. The **verify side**
(RS256/JWKS in `jwt.go`/`jwks.go`, OFF-by-default seam) is **already shipped and unit-proven**; only an
isolated gate + a coordinated cross-repo flip remain.

1. **PROVE-FIRST (isolated):** author `scripts/verify/mNN-rs256-issuer-isolated.sh` under
   `COMPOSE_PROJECT_NAME=rs256-probe` (throwaway network/volumes on /mnt/storage). Bring up a gotrue/IdP
   that signs RS256 + publishes `.well-known/jwks.json`, a Kong configured RS256 (`rsa_public_key` from
   that JWKS), and tenant-control with `JWT_ALG=RS256` + `JWKS_URL`. Assert: token header `alg=RS256`;
   the token validates through Kong on a real protected route (200 + correct `X-User-Id`); an HS256
   forgery signed with the RSA modulus → 401; unknown-kid → 401. **Must PASS before touching real config.**
2. **ISSUER (cross-repo/vendored):** bump `docker/services/gotrue/Dockerfile` (currently
   `supabase/gotrue:v2.188.1`, HS256-only, no RS256/JWKS env) to an image supporting asymmetric JWT +
   JWKS, or put a small JWKS-publishing signer in front; supply the private key via Vault; confirm
   `GET <issuer>/.well-known/jwks.json` returns an RSA `sig` key with a stable `kid`.
3. **KONG (`kong.yml`):** change the `authenticated` consumer `jwt_secrets` from
   `algorithm:HS256/secret:__JWT_SECRET__` to `algorithm:RS256/rsa_public_key:<PEM>` (+ a
   `__JWT_RS256_PUBKEY__` token); teach the entrypoint sed block (`docker-compose.yml` ~108–123) to
   substitute the PEM. Kong keys on `iss` → no indefinite dual-alg; plan a brief coordinated window.
4. **VERIFIER (in-repo, ready):** set `JWT_ALG=RS256` + `JWKS_URL=<issuer>/.well-known/jwks.json` for
   tenant-control (`docker-compose.yml`:1087–1088). No code change.
5. **STAGE + GATE:** full stack on staging; re-run the isolated gate + the standard login/auth m-series +
   `make playground`; assert real login → RS256 token → 200 across /rest, /query, /data, /storage,
   /realtime, /functions.
6. **CUTOVER (irreversible, explicit human go):** flip prod in ONE coordinated deploy so
   issue+validate+verify move together; watch the 401 rate; keep the HS256 path for instant rollback
   until a full token TTL (`GOTRUE_JWT_EXP=3600s`) of clean traffic elapses, then remove HS256
   `jwt_secrets`.
7. **ROLLBACK:** revert env to HS256 + restore Kong HS256 `jwt_secrets` + revert the gotrue image.

## G-Vault — enforce Vault-backed credentials at `SECURITY_MODE=max`

**Why deferred:** not purely additive — it changes the mount-register request contract **and** the DB
schema (new `credential_ref` columns) and requires the data plane's per-mount Vault-provider resolve
path (today env-only via `DATA_PLANE_VAULT_*`) to be driven from the registry. Shipping the *negative*
(reject inline plaintext under max) without the *positive* vault-resolve path would lock max-tier
tenants out of registering **any** mount.

1. Add nullable `cred_provider`/`cred_reference`/`cred_version` columns to `public.tenant_databases` via
   a new `models/` migration; keep `connection_enc` nullable (a row is EITHER inline-encrypted OR a vault
   ref).
2. Extend `RegisterDatabaseRequest` (`internal/adapterregistry/models.go`) with optional
   `credential_ref`; in `Validate()` require EXACTLY one of `{connection_string, credential_ref}`.
3. In `Service.Register`, read effective `security_mode` from `packageForTenant` (already loaded,
   `packages.go SecurityMode`); if `max` → reject inline plaintext with a new `ErrPlaintextDsnForbidden`
   + require `credential_ref{provider:vault}`; else preserve today's encrypt path. Map the error to 403
   in `handler.go`.
4. Wire `GetConnection` to return provider/reference for ref-backed mounts so the data plane's existing
   `VaultProvider` (`credential.rs`, `resolver.rs from_env`) resolves it; configure `DATA_PLANE_VAULT_*`.
5. Author `scripts/verify/mNN-vault-enforce.sh` on a SCRATCH compose project: NEGATIVE (max tenant +
   inline plaintext → 4xx, 0 rows inserted); POSITIVE (same tenant + `credential_ref{provider:vault}` →
   201, data plane resolves the DSN from a scratch dev-mode Vault, real query succeeds); PARITY
   (baseline-tier inline plaintext still 201). Also run `make baas-verify`.
6. Keep enforcement OFF for non-max tiers; document the flip in `security-audit-asvs.md`.
7. Only after gates PASS, request the human push (kernel rule #9).

## G-Net — per-plane network segmentation

**Safe half first (agent under review):**
1. Add `deploy/helm/mini-baas/templates/networkpolicy.yaml` gated on `.Values.networkPolicy.enabled`
   (default false) + a component→plane map + allowlist in `values.yaml`; reuse
   `mini-baas.selectorLabels`.
2. Prove: `helm template … --set networkPolicy.enabled=false | grep -c NetworkPolicy` → 0 (baseline
   parity); `--set networkPolicy.enabled=true` → default-deny + allowlist edges; run `helm lint` +
   `kubeconform`.

**Unsafe half (human-driven — re-networks the live docker stack):**
3. Author a SEPARATE overlay `docker-compose.netseg.yml` (do NOT edit the base `networks:` block)
   defining app/control/data/observability bridges and dual-attaching kong, query-router,
   adapter-registry-go, data-plane-router-rust + every engine/redis/vault/prometheus edge.
4. Enumerate every talking pair first: `grep -niE 'http://|:[0-9]{4}|_URL' docker-compose.yml` so no
   edge is dropped.
5. Bring up ISOLATED: `docker compose -p netseg-probe -f docker-compose.yml -f docker-compose.netseg.yml
   up -d` (NOT the shared default stack).
6. POSITIVE probe: exec query-router, curl a real `/query` resolving a mount via
   `adapter-registry-go:3021` → 200. NEGATIVE probe: exec an observability container,
   `nc -z postgres 5432` → refused/timeout.
7. `docker compose -p netseg-probe down -v`. Only after both probes pass, decide whether the overlay
   becomes documented prod topology; never fold it into the base compose the live stack runs.

## G-Hdr — enable adapter-registry identity HMAC stack-wide

**Why deferred:** the write+unit+isolated-gate work is in-repo and reversible, but making it *effective*
means flipping `ADAPTER_REGISTRY_IDENTITY_HMAC=1` on the LIVE `adapter-registry-go` — the mount-resolution
hot path for live osionos (every `/connect` + `/databases` read). If any in-repo injector is missed —
notably the Rust `data-plane-router-rust` resolve path — the flip turns those callers into instant 401s.
Value is LOW (defense-in-depth on a path already protected by `SERVICE_TOKEN_MODE=hmac` + the write guard
+ RLS).

1. (in-repo) Add a Go signer in `tenants/provision.go` `register()`/`findMountID()`: after
   `X-Baas-Tenant-Id`, set `X-Baas-Identity-Auth = shared.ComputeServiceSignature(serviceToken,"IDENTITY",
   userID+"\n"+tenantScope,nil,now)`.
2. Add a TS twin `computeIdentityAuth(token,userId,tenantId)` in
   `src/libs/common/src/security/service-auth.ts`; attach `X-Baas-Identity-Auth` wherever
   `query.service.ts` / `rust-data-plane.proxy.ts` set `X-Service-Token` to adapter-registry.
3. **AUDIT every caller signs:** `grep -rniE 'ADAPTER_REGISTRY_URL|adapter-registry-go:3021' --include=*.ts
   --include=*.go --include=*.rs` — CRITICALLY confirm the Rust `data-plane-router-rust` resolve path
   emits the header, else it 401s on flip.
4. Extend `identity_test.go`; `go test ./internal/adapterregistry/...`.
5. ISOLATED gate: `docker compose -p idhmac-probe up -d adapter-registry-go tenant-control postgres` with
   `ADAPTER_REGISTRY_IDENTITY_HMAC=1`; assert signed→200, spoof→401, skew→401, flag-off→200.
6. Only after EVERY injector is confirmed signing, flip `ADAPTER_REGISTRY_IDENTITY_HMAC=1` on live
   adapter-registry-go and immediately smoke a real osionos `/connect` + `/query`; roll back on any 401.
7. Leave storage-router (`IDENTITY_HEADER_MODE=compat`, Kong-fronted) OUT of scope — that is the genuine
   cross-repo Kong-signing change.

## G-Rotate — atomic key-rotation (JWT_SECRET + service token, without restart)

> Note: DSN/credential rotation already ships (`registry.rs drain_pool_key` + `/v1/admin/rotate`). This
> residual is specifically `JWT_SECRET` + service-token rotation-without-restart.

**Service-token half (in-repo, do first, low blast radius):**
1. Add optional `INTERNAL_SERVICE_TOKEN_PREV` to Go `shared.VerifyServiceRequest` (`shared/token.go`):
   verify against expected; on fail AND prev non-empty, verify against prev (constant-time both).
2. Mirror in the Rust caller/bypass (`service_auth.rs`; `routes.rs` verify ~L1076/L1180) reading an
   optional prev, default-empty.
3. Author `scripts/verify/mNN-rotate.sh` on a SCRATCH compose project: old-token-accepted-during-window;
   third-unrelated-token-rejected (401); old-rejected-after-window-cleared. Run `make baas-verify`.
4. Document the swap: set `PREV=current`, set primary=new, roll peers one at a time, clear `PREV` after
   grace.

**JWT half (cross-repo, human + careful):**
5. Confirm vendored gotrue can sign under `JWT_SECRET` while PostgREST accepts `JWT_SECRET` + a secondary
   key (a vendored-gotrue + postgrest config change, NOT this repo's Rust/Go).
6. Stand up STAGING gotrue+postgrest (never the shared live stack); prove a session minted under the new
   secret AND one under the old both validate during the grace window, then old rejected after.
7. Wire `vault-rotate-approles`-style orchestration to bump `JWT_SECRET` + `PREV_JWT_SECRET` and trigger
   gotrue re-sign WITHOUT a hard restart — only after staging proof.
8. Update `security-audit-asvs.md` G-Rotate once both halves are gated. Do NOT run the JWT half against the
   live login flow unsupervised (kernel rule #9).
