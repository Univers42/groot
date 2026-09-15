# 6. Veille technologique — technical evolutions & security issues for installing/configuring the work environment — prove it

**Question (FR).** *Réaliser une veille technologique sur les évolutions techniques
et les problématiques de sécurité en lien avec l'installation et la configuration
d'un environnement de travail.*

**Answer.** The watch is **automated and codified in the repo** (not a manual
notebook): bots and CI continuously surface dependency/toolchain evolutions and
security advisories, and the whole work environment is installed+configured
reproducibly through version-pinned containers. Three pillars, all citable.

## A. Technical-evolution watch (dependencies + toolchain)  ✅
- **Automated update bots**: `renovate.json` **and** `.github/dependabot.yml` open
  PRs as dependencies/images move.
- **Pinned + tracked toolchains** (bump procedure in `apps/grobase/RELEASE.md`):
  `golang:1.25-bookworm`, `rust:1.96-*` (grobase Dockerfiles), `node:22-alpine`
  (grobase-website Dockerfile).
- **Supply-chain cool-down**: `minimum-release-age=10080` (7 days) in
  `apps/osionos/app/.npmrc` + `pnpm-workspace.yaml` — refuses brand-new releases
  for a week to dodge compromised publishes.
- **Adoption discipline** "shadow → parity → cutover → delete" (TS → Rust data
  plane): new tech runs beside the old and is validated before any switch
  (`apps/grobase/CLAUDE.md`, binding rule #2). Modern stack: Astro, Tailwind v4,
  Vite, pnpm, Go 1.25, Rust.

## B. Security-issue watch (CVEs + SAST + secrets)  ✅
- **Dedicated CI workflows**: `.github/workflows/supply-chain.yml`,
  `mini-baas-security.yml`, `nightly-proof.yml`.
- **Continuous scanners**: cargo-audit + govulncheck (`make audit-deps`); OSV,
  Trivy, Semgrep `p/owasp-top-ten`, TruffleHog/gitleaks (`make baas-security-scan`,
  `make baas-security-audit`) — see [04 §C](04-tests.md#c-security-tests).
- **Curated triage record**: `.trivyignore`, `.semgrepignore`,
  `apps/grobase/.gitleaks.toml`, `.trufflehogignore` (documented exceptions = the
  watch's decision log).

## C. Install + configure the work environment (reproducible & validated)  ✅
- **Docker-first, host-free**: *"Never install dependencies on the host"* — the
  environment is codified in Dockerfiles + `docker-compose` + Makefiles; `make all`
  / `make quickstart` install and configure it idempotently.
- **Fresh-machine validation in CI**: `.github/workflows/fresh-machine.yml` proves a
  clean clone installs+configures correctly; runs logged in `FRESH-START-LOG.md` /
  `FRESH-START-AGENT-PROMPT.md`.
- **Config docs**: `wiki/SETUP.md`, `wiki/colleague-make-all-onboarding.md`,
  `wiki/best-practices.md`, `apps/grobase/RELEASE.md`.
- **Secure-by-default config**: secrets never in repo (vault42; `.env` chmod 600,
  gitignored), local TLS CA bootstrap, WAF — the *security problematics* of env
  config are handled in [05](05-securite-rgpd-anssi.md).

⚠️ Note: renovate + dependabot are both wired (mild redundancy); the automation is
strong, the human changelog cadence lighter (`wiki/changelog/`, `RELEASE.md`).
