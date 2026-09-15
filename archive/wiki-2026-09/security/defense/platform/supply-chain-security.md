# Supply-Chain Security — platform / infrastructure (cross-cutting)

> Every JavaScript dependency installed in CI must be at least 7 days old, locked to a verified-integrity store, and free of lifecycle scripts; Renovate and Dependabot enforce the same discipline for human-driven upgrades.

## What it is (the concept)

**Software supply-chain security** is the practice of controlling exactly which third-party artifacts enter a build: verifying their **integrity** (content matches what the registry published), enforcing **provenance delay** (newly published packages carry higher malicious-upload risk), and eliminating **install-time code execution** (postinstall/lifecycle scripts are a common vector). The goal is to shrink the window in which a compromised or typosquatted package can silently enter the dependency graph. **Frozen lockfiles** are a complementary control: they prevent a dependency resolver from silently pulling in a newer version than the one reviewed.

## What it defends against

See [Software Supply Chain Attack](../../attack/supply-chain-security.md).

In this stack, the threat is concrete: pnpm and npm manage hundreds of transitive dependencies across three frontends (osionos, opposite-osiris, mail/calendar). A malicious actor who publishes a package to npm immediately after a legitimate release — or who compromises a transitive dependency — could execute arbitrary code on the CI runner or in a developer's shell during `npm install`. Lifecycle scripts (`postinstall`, `prepare`) are the canonical injection point; this project disables them entirely at install time and allows only a hard-coded allowlist of packages that genuinely require a build step.

## How platform implements it

Four interlocking controls are committed to the repository:

**1. pnpm store-integrity and release-age hold** (`apps/osionos/app/.npmrc`)

```
minimum-release-age=10080        # 7 days before a newly published version is eligible
verify-store-integrity=true      # content-hash check against the store on every install
strict-store-pkg-content-check=true
prefer-frozen-lockfile=true      # abort if lockfile is out of sync with package.json
```

The companion `apps/osionos/app/pnpm-workspace.yaml` mirrors `minimumReleaseAge: 10080` so the pnpm rules engine enforces the same hold regardless of which config path it reads.

**2. Explicit postinstall allowlist** (`apps/osionos/app/package.json`, field `pnpm.onlyBuiltDependencies`)

```json
"pnpm": {
  "onlyBuiltDependencies": [
    "@tailwindcss/oxide", "esbuild", "playwright", "protobufjs", "sass-embedded"
  ]
}
```

Any dependency not on this five-entry list is silently denied its lifecycle scripts; adding a new native-build dependency requires a deliberate, reviewable edit.

**3. CI frozen-install gate** (`.github/workflows/supply-chain.yml`)

The `npm-frozen-installs` job runs `npm ci --ignore-scripts` for every npm-managed workspace (mail, calendar, markengine) and the `pnpm-frozen-installs` job runs `pnpm install --frozen-lockfile --prefer-offline --ignore-scripts` for osionos/app and opposite-osiris. Both jobs run on every `pull_request` and `push` to `main`, with `permissions: contents: read` (no write grants). A drift between `package.json` and the lockfile causes an immediate CI failure before any code runs.

**4. Automated upgrade policies** (`renovate.json` + `.github/dependabot.yml`)

`renovate.json` imposes `"minimumReleaseAge": "3 days"` on all npm/pnpm managers and requires `"dependencyDashboardApproval": true` before any update PR is merged — a human checkpoint on every dependency bump. GitHub Actions pins are kept current by `dependabot.yml` (weekly, `github-actions` ecosystem only; application manifests live in submodule repos with their own Dependabot configs).

## How we know it is applied

The CI gate is non-optional: `.github/workflows/supply-chain.yml` runs on `pull_request` and `push` branches `main` with `cancel-in-progress: true`. The relevant steps are:

```yaml
# npm-frozen-installs job (line 39-45):
- name: Verify npm lockfiles without lifecycle scripts
  run: |
    set -euo pipefail
    for dir in apps/mail apps/calendar apps/osionos/app/src/shared/lib/markengine; do
      (cd "${dir}" && npm ci --ignore-scripts)
    done

# pnpm-frozen-installs job (line 72-80):
- name: Verify pnpm lockfiles with approved build scripts only
  run: |
    set -euo pipefail
    for dir in apps/osionos/app apps/opposite-osiris; do
      (cd "${dir}" && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts)
    done
```

A lockfile that has drifted, a package that injects a new lifecycle script, or a `pnpm-lock.yaml` regenerated outside Docker will all break this job before the PR can merge.

## Reference

The [OWASP Software Supply Chain Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html) defines the canonical controls — integrity verification, provenance, and build-script isolation — that this project implements across both install-time enforcement and CI gating. The OWASP guidance maps directly to OWASP Top 10 A06 (Vulnerable and Outdated Components) and A08 (Software and Data Integrity Failures), both of which are addressed by the lockfile discipline and release-age delay described above.

## Residual risk / assumptions

- **Submodule boundary:** the `.npmrc` release-age policy lives in `apps/osionos/app` (the osionos submodule). The root superproject does not own npm/pnpm manifests; supply-chain policy for mail, calendar, and opposite-osiris depends on each submodule's own config being kept in sync.
- **3-day vs 7-day gap:** Renovate enforces a 3-day hold; the pnpm `.npmrc` enforces 7 days. A Renovate-generated PR could reference a version the local pnpm store would still refuse, but the CI `--prefer-offline` flag means the store state during CI may differ from local developer installs.
- **Allowlist drift:** the `onlyBuiltDependencies` list is static; a legitimate new native dependency added without updating the list will fail its build step silently, not loudly — the error is a missing binary at runtime, not a rejected install.
- **GitHub Actions themselves:** Dependabot pins Actions by SHA but the weekly schedule means up to six days of exposure before a compromised Action is detected. No SLSA provenance verification is applied to `actions/checkout` or `actions/setup-node` beyond the SHA pin.
- **No SBOM generation:** there is no automated Software Bill of Materials export; inventory is implicit in the lockfiles, not a published artifact.
