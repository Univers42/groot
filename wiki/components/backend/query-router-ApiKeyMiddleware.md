# query-router + ApiKeyMiddleware — the identity broker (the proxy ↔ reverse-proxy handshake)

> **In one sentence.** The query-router's API key middleware exchanges a raw API key for a cryptographically signed identity envelope that the data plane trusts, enabling the proxy-to-reverse-proxy handshake.

## What it is & why it exists

The identity broker sits at the boundary between Kong (the [reverse proxy](glossary.md#reverse-proxy)) and the query-router (the [application proxy](glossary.md#application-proxy)). Its job is to take a cleartext [API key](glossary.md#api-key) (or a pair of API key + [Bearer JWT](glossary.md#bearer-jwt)) from the client, verify the API key against the [control plane](glossary.md#control-plane)'s database of stored hashes, resolve the owner (either the app key itself or the JWT's user), and mint a signed [HMAC](glossary.md#hmac) envelope that downstream services—the permission engine and Rust [data plane](glossary.md#data-plane)—will trust without re-verifying.

Without this handshake, the data plane would have to call the control plane on every request, or trust raw headers that a compromised client could forge. Instead, the middleware does the expensive verification once, signs the result, and the data plane can verify the signature cheaply using a local key.

## How it works

- Client sends a request with X-Baas-Api-Key header (and optionally a Bearer JWT in the Authorization header).
- The middleware extracts the API key and checks the cache (B4 fast path: if seen in the last 30 seconds, return the cached result).
- If not cached, POST the API key (as `{"key": "..."}`) to the control plane's /v1/keys/verify endpoint, signing the request with INTERNAL_SERVICE_TOKEN using HMAC-SHA256.
- The control plane parses the key prefix, queries for candidate rows in the tenant_api_keys table, and constant-time-compares the cleartext payload against stored [Argon2id](glossary.md#argon2id) or fast-scheme hashes.
- On match, the control plane returns {valid: true, tenant_id, key_id, scopes}; on mismatch or expiry, {valid: false, reason: "..."}.
- The middleware caches the response ([Cache TTL](glossary.md#cache-ttl) 30 seconds by default) and checks if a valid Bearer JWT was also provided. If so, it verifies the JWT signature (HS256, [constant-time compare](glossary.md#constant-time-compare)), extracts the user's sub and role, and makes the user the owner; otherwise the app key is the owner.
- The middleware mints a [signed envelope](glossary.md#signed-envelope) using signIdentityEnvelope(): a canonical string (method, path, tenant, project, user, role, body-hash, timestamp, nonce) is HMAC-signed with the local INTERNAL_IDENTITY_HMAC_KEY, producing headers like x-baas-signature=v1=&lt;hex&gt;.
- The signed envelope is set onto req.headers and the request flows to the permission engine and data plane.
- Downstream services (permission engine, Rust data plane) verify the envelope's signature using the same canonical string and local keys, accepting it only if the signature is valid and the [nonce](glossary.md#nonce) is fresh (within the max-skew window and not seen before).
- The Rust data plane receives the identity ([Tenant ID](glossary.md#tenant-id), user_id, roles, scopes, source=signed_envelope) serialized in the request body, uses it to set Postgres GUCs (for [RLS (Row-Level Security)](glossary.md#rls-row-level-security)) or app-logic [owner scoping](glossary.md#owner-scoping), and executes the query filtered to the owner.

## The code that does it

**What to look at:** The main NestJS middleware flow: extract X-Baas-Api-Key, verify it with the control plane, resolve owner-scope if a Bearer JWT is present, mint a signed envelope, then pass it downstream.

```ts
// apps/grobase/src/libs/common/src/middleware/api-key.middleware.ts:85-137
  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    const apiKey = pickHeader(req, 'x-baas-api-key') ?? pickHeader(req, 'apikey');
    if (!apiKey) return next();

    // If the caller already provided a verified tenant envelope (signed
    // gateway), respect that and skip key verification.
    if (pickHeader(req, 'x-baas-tenant-id')) return next();

    let verify: VerifyResponse;
    try {
      verify = await this.verify(apiKey);
    } catch (err) {
      this.logger.warn(`api-key verify failed: ${(err as Error).message}`);
      res
        .status(503)
        .json({ error: 'auth_verify_unavailable', message: 'tenant-control unreachable' });
      return;
    }

    if (!verify.valid) {
      res.status(401).json({ error: 'invalid_api_key', reason: verify.reason ?? 'invalid' });
      return;
    }

    // Per-user owner-scoping: when a verified GoTrue user JWT rides alongside
    // the app key, the OWNER is the user (`user:<sub>`) and the JWT's role flows
    // through (so an `admin` JWT triggers the data plane's F2 bypass). Absent or
    // unverifiable JWT → the app key is the owner = the pre-existing behavior.
    const owner = this.resolveOwner(req, verify);

    // Mint a signed identity envelope so strict-mode AuthGuard accepts the
    // api-key caller (raw identity headers are rejected in strict mode). It is
    // self-signed over the same canonical string + key set the verifier uses.
    try {
      const envelope = signIdentityEnvelope(req, {
        tenantId: verify.tenant_id!,
        userId: owner.userId,
        role: owner.role,
        appId: 'api-key',
        scopes: verify.scopes ?? [],
      });
      for (const [name, value] of Object.entries(envelope)) {
        req.headers[name] = value;
      }
    } catch (err) {
      this.logger.error(`identity envelope signing failed: ${(err as Error).message}`);
      res
        .status(500)
        .json({ error: 'identity_unavailable', message: 'identity signing key not configured' });
      return;
    }
    next();
  }
```

**What to look at:** The verify call to the Go control plane: checks cache first (fast path for repeat requests), POSTs to /v1/keys/verify with HMAC-signed headers, caches the result with a TTL.

```ts
// apps/grobase/src/libs/common/src/middleware/api-key.middleware.ts:145-163
  private async verify(key: string): Promise<VerifyResponse> {
    const cached = this.cache.get(key);
    const now = Date.now();
    if (cached && cached.exp > now) return cached.res;

    const payload = JSON.stringify({ key });
    const headers = {
      'Content-Type': 'application/json',
      ...serviceAuthHeaders(this.serviceToken, 'POST', '/v1/keys/verify', payload),
    };
    const { status, raw } = await this.postVerify(payload, headers);
    if (status !== 200 && status !== 401) {
      throw new Error(`unexpected status ${status}`);
    }
    const body = JSON.parse(raw) as VerifyResponse;
    this.cache.set(key, { exp: now + this.cacheTtlMs, res: body });
    this.pruneCache(now);
    return body;
  }
```

**What to look at:** Owner-resolution logic: if a valid GoTrue user JWT rides alongside the API key, the user becomes the owner (userId via user:sub) and carries the JWT's role; otherwise the app key is the owner (api-key:&lt;keyId&gt;) with role=authenticated.

```ts
// apps/grobase/src/libs/common/src/middleware/api-key.middleware.ts:171-181
  private resolveOwner(req: Request, verify: VerifyResponse): OwnerIdentity {
    const fallback: OwnerIdentity = {
      userId: `api-key:${verify.key_id ?? ''}`,
      role: 'authenticated',
    };
    const auth = pickHeader(req, 'authorization');
    if (!auth || !auth.toLowerCase().startsWith('bearer ') || !this.jwtSecret) return fallback;
    const claims = this.verifyUserJwt(auth.slice(7).trim());
    if (!claims?.sub) return fallback;
    return { userId: `user:${claims.sub}`, role: claims.role || 'authenticated' };
  }
```

**What to look at:** The forward decision: proxies to Rust when RUST_DATA_PLANE_FORWARD=1 AND the engine is in the allow-list (default: postgresql,mongodb).

```ts
// apps/grobase/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts:220-223
  /** Returns true when the proxy should handle this `(engine)` instead of TS. */
  shouldForward(engine: string): boolean {
    return this.forwardEnabled && this.forwardEngines.has(engine.toLowerCase());
  }
```

**What to look at:** Identity envelope serialization to the Rust data plane: tenant, project, app, user, roles, scopes, and source marker (signed_envelope) so the Rust side knows the identity is verified.

```ts
// apps/grobase/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts:405-417
  private buildIdentity(context: RustProxyContext): Record<string, unknown> {
    return {
      tenant_id: context.tenantId,
      project_id: context.projectId ?? null,
      app_id: context.appId ?? null,
      user_id: context.userId,
      roles: context.roles ?? [],
      scopes: context.scopes ?? [],
      // Must match data_plane_core::IdentitySource (snake_case): the TS proxy
      // talks to Rust via the internal HMAC envelope path.
      source: 'signed_envelope',
    };
  }
```

**What to look at:** The Go control-plane verify entry point: parses the key prefix, checks the cache (B4 fast path), queries for candidates, constant-time hash-compares against stored hashes, and returns tenant_id + scopes.

```go
// apps/grobase/src/control-plane/internal/tenants/keys_verify.go:32-56
// VerifyKey resolves a cleartext key to a tenant slug + scopes if valid.
// Updates last_used_at on success. Constant-time hash compare.
func (s *Service) VerifyKey(ctx context.Context, full string) (VerifyKeyResponse, error) {
	prefix, payload, err := parseKey(full)
	if err != nil {
		return VerifyKeyResponse{Valid: false, Reason: "invalid_format"}, nil
	}
	hash, cached, hit := s.cacheGet(full)
	if hit {
		return cached, nil
	}
	rows, err := s.db.AdminQuery(ctx, verifyKeySQL, prefix)
	if err != nil {
		return VerifyKeyResponse{}, err
	}
	defer rows.Close()
	resp, err := s.matchKeyRows(rows, prefix, payload)
	if err != nil || !resp.Valid {
		return resp, err
	}
	if s.verifyC.enabled() {
		s.verifyC.put(hash, resp)
	}
	return resp, nil
}
```

**What to look at:** Constant-time row matching: scans candidates for a hash that matches (Argon2id or fast scheme), returns tenant_id + scopes on match, updates last_used_at and optionally upgrades legacy hashes (async).

```go
// apps/grobase/src/control-plane/internal/tenants/keys_verify.go:80-103
func (s *Service) matchKeyRows(rows pgx.Rows, prefix, payload string) (VerifyKeyResponse, error) {
	for rows.Next() {
		var (
			keyID, tenantSlug, storedHash string
			scopes                        []string
			expired                       bool
		)
		if err := rows.Scan(&keyID, &tenantSlug, &storedHash, &scopes, &expired); err != nil {
			return VerifyKeyResponse{}, err
		}
		if expired {
			return VerifyKeyResponse{Valid: false, Reason: "expired"}, nil
		}
		if !s.hasher.verifyKeyHash(payload, prefix, storedHash) {
			continue
		}
		go s.touchLastUsed(keyID)
		if !isFastHash(storedHash) && os.Getenv("KEY_HASH_UPGRADE") != "0" {
			go s.upgradeKeyHash(keyID, payload, prefix)
		}
		return VerifyKeyResponse{Valid: true, TenantID: tenantSlug, KeyID: keyID, Scopes: scopes}, nil
	}
	return VerifyKeyResponse{Valid: false, Reason: "no_match"}, nil
}
```

## Where it sits in the request flow

This component lives at a critical seam: Kong (the reverse proxy, public entry) forwards the request to the query-router (application proxy). The ApiKeyMiddleware is the first stop in the query-router, running before the permission engine and data plane. It trades a raw API key (or API key + JWT pair) for a signed [identity envelope](glossary.md#identity-envelope). Downstream, the permission engine consults the identity for ABAC decisions, and the Rust data plane uses it for owner-scoping at the database level via RLS or schema/database [isolation strategy](glossary.md#isolation-strategy). The control plane (the Go backend, alongside [GoTrue](glossary.md#gotrue) for user JWTs) is called once per unique API key per cache-TTL to validate the key and return the tenant; thereafter the middleware's signature replaces the control plane's authority.

## Remember this

> One signed envelope, minted once per request by the middleware after control-plane verification, replaces the need for the data plane to reverify—making the identity broker the trusted proxy between Kong and the data layer.

---
**See also:** [reverse_proxy.md](reverse_proxy.md) · [owner_isolation.md](owner_isolation.md) · [rls.md](rls.md) · [ABAC_RBAC.md](ABAC_RBAC.md) · [Glossary](glossary.md)
