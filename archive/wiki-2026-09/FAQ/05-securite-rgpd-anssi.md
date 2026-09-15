# 5. RGPD + ANSSI + scores WCAG 2.1

## RGPD / GDPR — respected, with code  ✅
- **GDPR service** `apps/grobase/src/apps/gdpr-service/` (`mini-baas-gdpr-service`):
  erasure (`/deletion-requests`), granular **consent** (`/consents`), **DSAR ZIP
  export** (`GET /export`) — `…/README.md:17`.
- **Portability (Art. 20)** `src/control-plane/internal/export/` — flag
  `TENANT_EXPORT_ENABLED`, migration `052_tenant_exports.sql`.
- **Erasure (Art. 17)** `…/internal/erase/` — flag `HARD_ERASE_ENABLED`, migration
  `048_tenant_erasure.sql`; rights mapped to articles in
  `…/internal/compliance/collect_env_posture.go:36`.
- **Encryption at rest** AES-256-GCM CMEK `…/internal/cmek/envelope.go:46` (mig
  `061`); **tamper-evident audit chain** SHA-256 `…/internal/audit/chain.go:19`
  (mig `047`); **per-request RLS owner-scoping** (`auth.uid()=owner_id`;
  `read_scoped` mig `070`). Privacy docs `wiki/gdpr/*`.

## ANSSI-aligned hygiene — respected in practice  ✅ ⚠️
*Alignment with ANSSI security-hygiene guidance, not a formal certification (the
string "ANSSI" is not claimed in code).* Threat model: `apps/grobase/SECURITY.md`.
- **WAF** nginx + ModSecurity + OWASP CRS (gate `m140`); **Kong** JWT (alg-pinned,
  no `none`), per-route rate-limiting, **HSTS 2y+preload**, `X-Frame-Options: DENY`.
- **Auth**: API keys 160-bit salted SHA-256 + `KEY_HASH_PEPPER`; TOTP MFA, OAuth/OIDC,
  passkeys (`PASSKEYS_ENABLED`), SSO/SCIM. **TLS** `SECURITY_MODE=max` ⇒ `verify-full`.
- **Secrets** vault42, none in repo (`.env` 600, gitignored) + TruffleHog/gitleaks;
  **net-segmentation** overlay `docker-compose.netseg.yml`; SAST/SCA/DAST →
  [04 §C](04-tests.md#c-security-tests).
- ⚠️ `SECURITY.md` claims per-PR CI scanning; the proven path is local
  `make baas-security-scan` + the `supply-chain.yml` / `mini-baas-security.yml` workflows.

## Scores WCAG 2.1 — MEASURED  ✅ (grobase marketing site · 2026-06-28)
Ran the audit gate (Lighthouse + pa11y `WCAG2AA`) — **all green**:

| Page | Perf | Accessibility | Best-pr. | SEO | pa11y WCAG2AA |
|---|---|---|---|---|---|
| `/`          | 99  | **100** | 100 | 100 | 0 issues |
| `/pricing/`  | 100 | **100** | 100 | 100 | 0 issues |
| `/security/` | 100 | **100** | 100 | 100 | 0 issues |

Full quality gate = **14 PASS / 0 FAIL** (+ html-validate, CSP-violation check, icon-safety).
Reproduce: **`make grobase-audit`** — the missing `grobase-site-audit` compose service
was wired into `docker-compose.yml` (2026-06-28); it builds the website Dockerfile's
`audit` stage and runs `scripts/audit/run-all.mjs`. Scope = the marketing site; app-frontend
a11y tooling (jsx-a11y / pa11y / axe / Lighthouse ≥90) → [02](02-accessibilite-wcag.md).
Manual checklist: `wiki/acccessibility/wcag.md`.
