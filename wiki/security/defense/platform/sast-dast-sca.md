# Multi-tool Security CI Gate (SAST + SCA + Container + DAST) — platform / infrastructure (cross-cutting)

> Every pull request and push to `main` must pass an aggregated security gate that combines static analysis, dependency auditing, container scanning, secret detection, and opt-in dynamic testing before a merge is permitted.

## What it is (the concept)

**Static Application Security Testing (SAST)** analyses source code for injectable patterns and known-bad constructs without running the program. **Software Composition Analysis (SCA)** cross-references the dependency graph against public vulnerability databases (npm Advisory DB, RustSec, Go vuln DB, OSV) to surface **known-CVE components**. **Container scanning** extends SCA to OS-level packages baked into Docker images. **Dynamic Application Security Testing (DAST)** sends live HTTP traffic against a running instance to find exploitable endpoints that static analysis cannot reach. Combining all four into a single **aggregated verdict gate** prevents any one tool's finding from being silently bypassed.

## What it defends against

See [Vulnerable and Outdated Components](../../attack/sast-dast-sca.md).

In this application the threat is concrete: the backend is a polyglot monorepo (TypeScript/Node, Go, Rust) whose dependency closure spans hundreds of transitive packages across three ecosystems. A single unpatched JWT library, a compromised npm package, or an OS CVE in a base image can expose the auth path, the data plane query router, or the realtime engine to remote exploitation — none of which is visible without automated scanning at merge time.

## How platform implements it

The primary enforcement mechanism is [`.github/workflows/mini-baas-security.yml`](../../../../.github/workflows/mini-baas-security.yml), a GitHub Actions workflow that triggers on every `pull_request` and every `push` to `main`. It runs eight parallel jobs and then a gate job that aggregates their results:

**SAST — Semgrep** (`sast-semgrep`): runs the official `semgrep/semgrep:latest` Docker image with five rule packs (`p/owasp-top-ten`, `p/typescript`, `p/dockerfile`, `p/nodejs`, `p/javascript`) and emits a SARIF report uploaded to the GitHub Security tab. Scope is controlled by [`.semgrepignore`](../../../../.semgrepignore), which excludes `node_modules/`, `dist/`, `vendor/`, generated documentation, and Python venvs so that the scan covers only first-party source. Inline `# nosemgrep` suppressions on reviewed nginx config patterns are additionally excluded at the file level to prevent GitHub code-scanning surfacing them as open alerts.

**SCA — npm audit** (`sca-npm-audit`): runs `npm audit --audit-level=high --no-fund` against `apps/grobase/src` and `apps/grobase/sdks/js` on Node 22. The `--audit-level=high` threshold means any HIGH or CRITICAL advisory in the BaaS Node dependency graph fails this job.

**SCA — cargo-audit** (`sca-cargo-audit`): installs `cargo-audit --locked` and audits two Rust workspaces (`apps/grobase/src/data-plane-router` and `apps/grobase/infra/docker/services/realtime/realtime-agnostic`). The job is blocking. Three RUSTSEC advisories (`RUSTSEC-2026-0098`, `-0099`, `-0104`) are `--ignore`d with inline justification: they arrive solely through `tiberius 0.12.3` (the MSSQL adapter's `rustls 0.21` chain), which has no upstream fix; the ignore flags are removed when a `rustls-0.2x` tiberius release lands.

**SCA — govulncheck** (`sca-govulncheck`): runs `govulncheck ./...` against `apps/grobase/src/control-plane`. Unlike a naive `go list` advisory scan, `govulncheck` uses reachability analysis — a vulnerability only fails the gate if the vulnerable symbol is actually called in the compiled binary, eliminating noise from transitive imports that are never exercised.

**Container — Trivy** (`container-trivy`): performs a filesystem scan (`--scan-type fs`) over the repository root at `HIGH,CRITICAL` severity with `--ignore-unfixed`, producing a SARIF report. Excluded from the scan scope are all submodule frontend apps (gated by their own repos' CI and the Supply Chain workflow) and all `node_modules/`/`vendor/` trees. When the representative `mini-baas/query-router:ci` image builds successfully, a supplementary image scan runs; if the build fails (e.g., transient Docker Hub timeout), the gate is not failed — the filesystem scan is the primary SCA path. A single residual is accepted in [`.trivyignore`](../../../../.trivyignore):

```
# glib 0.18.5 (apps/osionos-desktop/src-tauri/Cargo.lock) — GHSA-wrw7-89jp-8q8g
# Fix (glib 0.20) is a major gtk-rs/Tauri bump; severity MEDIUM; not in any CI build path.
GHSA-wrw7-89jp-8q8g
```

**Secret detection** (`secret-trufflehog`, `secret-gitleaks`): TruffleHog scans the diff (`base..head`) with `--only-verified` to surface confirmed credential leaks. gitleaks runs `--no-git` against the `apps/grobase` working tree with its own `.gitleaks.toml` ruleset, exits non-zero on any finding (`--exit-code 1`), and is a blocking gate.

**DAST — ZAP baseline** (`dast-zap`): intentionally opt-in only (`if: github.event_name == 'workflow_dispatch' && inputs.run_dast`). Standing up the full grobase backend in CI for every PR is too expensive; instead it is triggered manually via "Run workflow" or locally via `make baas-zap`. When triggered it brings the stack up on safe high ports (`BAAS_VERIFY_SAFE_PORTS=1`, WAF on `:18443`) and runs `apps/grobase/scripts/verify/zap-baseline.sh`.

The same tool families are available locally without a host install via Make targets in [`infrastructure/makes/baas-verify.mk`](../../../../infrastructure/makes/baas-verify.mk):

```makefile
baas-security-scan:  # SAST + SCA + Container + Secret (Docker-only)
    bash apps/grobase/scripts/security/run-security-scans.sh ...

baas-zap:            # DAST baseline against live WAF (stack must be up)
    bash apps/grobase/scripts/verify/zap-baseline.sh

baas-security-audit: # OSV deps + IaC misconfig + Nuclei/sqlmap
    bash apps/grobase/scripts/security/audit/run-audit.sh ...
```

## How we know it is applied

The `security-gate` job at the end of `.github/workflows/mini-baas-security.yml` (lines 442–469) aggregates the results of all seven blocking jobs and exits non-zero if any finished with a status other than `success` or `skipped`:

```yaml
security-gate:
  needs: [sast-semgrep, sca-npm-audit, container-trivy, secret-trufflehog,
          secret-gitleaks, sca-cargo-audit, sca-govulncheck]
  if: always()
  steps:
    - name: Aggregate verdict
      run: |
        ...
        if [[ ${fail} -eq 1 ]]; then
          echo "::error::Security gate FAILED — see individual job logs"
          exit 1
        fi
```

Because the workflow triggers on `pull_request` (all PRs) and `push: branches: [main]`, the gate fires on every proposed change and every direct push to the default branch. The cargo-audit and govulncheck jobs carry no `continue-on-error` flag, so a new advisory in either Rust or Go surfaces immediately as a failed PR check rather than an advisory annotation.

## Reference

The [CI/CD Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/CI_CD_Security_Cheat_Sheet.html) recommends treating the pipeline itself as a security boundary: every tool invocation should run in an isolated environment, findings should be aggregated into a single pass/fail verdict, and suppressions must be justified and auditable. This implementation follows that model — each scanner runs in its own job with minimal permissions (`contents: read`), SARIF results surface in the GitHub Security tab for audit, and all suppression decisions (`.semgrepignore`, `.trivyignore`, `--ignore` flags on cargo-audit) carry inline rationale with a stated remediation path.

## Residual risk / assumptions

- **Semgrep is advisory, not blocking.** The `sast-semgrep` job uses `continue-on-error: true` and guarantees a valid (possibly empty) SARIF output so the upload step never hard-fails the gate. A Semgrep finding alone does not block a merge; human triage via the Security tab is required.
- **DAST does not run on every PR.** The ZAP baseline is opt-in only. Live endpoint vulnerabilities (e.g., CSRF, reflected XSS, CORS misconfiguration) that Semgrep cannot detect will not be caught automatically on PRs — only on explicit manual workflow dispatch or local `make baas-zap` runs.
- **Snyk is conditional.** The `sca-snyk` job skips silently when `SNYK_TOKEN` is not configured (`echo "::notice::SNYK_TOKEN not configured — skipping Snyk"`), providing no SCA coverage for repositories or forks without that secret.
- **Container image scan is supplementary.** A Docker Hub rate-limit or build failure silently degrades the image scan to the filesystem scan only; base-image OS CVEs that are not present in the filesystem tree may be missed in that case.
- **Frontend submodule SCA relies on each submodule's own CI.** `apps/opposite-osiris`, `apps/osionos/app`, `apps/mail`, and `apps/calendar` are excluded from the Trivy filesystem scan and npm audit on the grounds that their own repositories gate their own dependency trees — this trust assumption holds only if those submodule CIs are actually running and enforcing equivalent thresholds.
- **The `.trivyignore` entry must be revisited.** `GHSA-wrw7-89jp-8q8g` (glib 0.18.5, Tauri desktop) is suppressed because glib 0.20 requires a breaking gtk-rs upgrade. If the desktop build enters a CI path or the severity is re-rated CRITICAL, the suppression must be removed and the dependency updated.
