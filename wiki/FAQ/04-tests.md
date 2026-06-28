# 4. Tests — jeu d'essai fonctionnel, unitaires, sécurité — demonstrate

**Answer.** Three layers: functional end-to-end (the *jeu d'essai*), unit/component
tests per plane, and an automated security battery.

## A. Jeu d'essai fonctionnel (functional E2E + test dataset)  ✅
- **Playwright** ~35 specs — `apps/osionos/app/tests/e2e/` (`functional/`, `smoke/`,
  `persistence/`, `visual/`): e.g. `blockCreation`, `dragAndDrop`, `databaseTemplates`,
  `inlineToolbar`. Run: `cd apps/osionos/app && bash scripts/docker-run.sh test-e2e`
  (fast subset: `test-e2e-smoke`); config `apps/osionos/app/playwright.config.ts`.
- **Org / restaurant simulations**: `make agency-sim`, `make gourmand-sim`, `make playground`.
- **Deterministic test dataset** (the literal *jeu d'essai*): ~29 idempotent seed
  scripts in `apps/grobase/scripts/seed/` (agency ≈ 950 rows over 10 tables; gourmand,
  hypertube, nimbus, `live-demo-generate.mjs`). Run: `make agency-all`, `make seed-live-demo`.

## B. Unit / component tests  ✅
- **osionos**: ~78 `*.test.ts` (`apps/osionos/app/tests/canvas/`, `node:test`).
- **grobase backend**: ~16 Jest `*.spec.ts` (`src/apps/**`, `src/libs/common`); Go
  ~91 `*_test.go` / 462 `func Test*`; Rust ~104 test files; JS SDK ~10 `*.test.mjs`.
- Run (from root): `make -C apps/grobase nestjs-ci · go-control-plane-check ·
  rust-data-plane-test`; SDK: `cd apps/grobase/sdks/js && npm test`.

## C. Security tests  ✅
- **SAST + container + secrets**: Semgrep (`p/owasp-top-ten`), Trivy, TruffleHog →
  `make baas-security-scan` (`apps/grobase/scripts/security/run-security-scans.sh`).
- **Dependency CVEs**: cargo-audit + govulncheck → `make audit-deps`.
- **OSV + IaC + Nuclei + sqlmap** → `make baas-security-audit`.
- **DAST**: OWASP ZAP baseline → `make baas-zap` (`BAAS_VERIFY_SAFE_PORTS=1`).
- **Numbered verify gates**: ~158 `m*.sh` in `apps/grobase/scripts/verify/` (each
  feature proven live), e.g. `m11-trust-boundary`, `m104-audit-chain`,
  `m157-kong-admin-not-exposed` → `make baas-verify-all`.

⚠️ opposite-osiris / mail / calendar ship `typecheck` (`tsc`/`astro check`) + `build`
only — no unit/e2e suite of their own (the editor osionos carries the functional load).
