# Supply-Chain Security — opposite-osiris (marketing + auth website)

> Every package installed into the opposite-osiris build is pinned to a known-good lockfile, stripped of lifecycle-script execution rights, and re-verified on every CI run — so no upstream package can inject arbitrary code during installation.

## What it is (the concept)

**Software supply-chain security** is the practice of ensuring that every third-party component entering a build is exactly what was reviewed, untampered, and free of malicious execution hooks. The two primary attack surfaces are **lifecycle scripts** (`postinstall`, `prepare`, etc.) that npm/pnpm run automatically during `install`, and **transitive dependency confusion** where a known-vulnerable or hijacked indirect dependency reaches the final bundle. Defences combine **lockfile integrity enforcement** (`--frozen-lockfile`) with **script execution suppression** (`--ignore-scripts`) and targeted **version overrides** to force safe transitive resolutions.

## What it defends against

See [Software Supply Chain Attack](../../attack/supply-chain-security.md).

opposite-osiris is a public-facing Astro/pnpm project that bundles credentials and session-handling logic into its auth-gateway container. A malicious `postinstall` hook in any dependency — direct or transitive — would execute with full filesystem and network access inside the build environment, able to exfiltrate `PUBLIC_BAAS_ANON_KEY`, write backdoors into the static bundle, or pivot to connected Docker services. A compromised transitive package (e.g. `yaml`, which is pulled through Astro/Vite) could silently alter configuration parsing at runtime.

## How opposite-osiris implements it

**Lifecycle-script suppression** is declared globally in [`apps/opposite-osiris/.npmrc`](../../../../apps/opposite-osiris/.npmrc):

```
ignore-scripts=true
engine-strict=true
```

`ignore-scripts=true` prevents pnpm from executing any package's `preinstall`, `install`, `postinstall`, `prepare`, or `prepublish` scripts. `engine-strict=true` causes the install to fail if the resolved Node version does not satisfy the `engines.node` field declared in [`apps/opposite-osiris/package.json`](../../../../apps/opposite-osiris/package.json) (`"node": ">=22.12.0"`), ensuring no accidental downgrade to a runtime with known CVEs.

**Transitive dependency pinning** is enforced in `package.json` at two levels (lines 72–78):

```json
"overrides": {
  "devalue": "^5.8.1"
},
"pnpm": {
  "overrides": {
    "yaml@<2.8.3": "^2.9.0"
  }
}
```

`devalue` is pinned via the npm `overrides` field so any version below `^5.8.1` is replaced across the whole tree. `yaml@<2.8.3` is pinned via `pnpm.overrides` to force all versions matching that range up to `^2.9.0`, closing a known parse-confusion vulnerability regardless of what Astro or Vite requests.

**Frozen-lockfile enforcement in containers** is applied in both production Dockerfiles:

- [`apps/opposite-osiris/docker/services/web/Dockerfile`](../../../../apps/opposite-osiris/docker/services/web/Dockerfile) line 75:
  ```
  RUN pnpm install --frozen-lockfile --ignore-scripts --config.node-linker=hoisted
  ```
- [`apps/opposite-osiris/docker/services/api-gateway/Dockerfile`](../../../../apps/opposite-osiris/docker/services/api-gateway/Dockerfile) line 26:
  ```
  RUN pnpm install --frozen-lockfile --ignore-scripts
  ```

`--frozen-lockfile` causes pnpm to abort if the resolved dependency graph does not match `pnpm-lock.yaml` exactly — any upstream tampering or drift is a hard build failure, not a silent update.

## How we know it is applied

The root CI workflow [`.github/workflows/supply-chain.yml`](../../../../.github/workflows/supply-chain.yml) runs on every push to `main` and on every pull request. The `pnpm-frozen-installs` job explicitly names `apps/opposite-osiris` and executes the same flags used in production containers (lines 77–79):

```yaml
for dir in apps/osionos/app apps/opposite-osiris; do
  echo "checking ${dir}"
  (cd "${dir}" && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts)
done
```

This is an active gate: the job fails (exit non-zero) if the lockfile is stale, if any package's resolved integrity hash does not match, or if pnpm cannot satisfy the engine constraint — blocking the merge before any compromised dependency reaches a container image.

## Reference

The [OWASP Software Supply Chain Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html) documents the full taxonomy of dependency-confusion, typosquatting, and lifecycle-script injection attacks that target the install phase of modern JavaScript projects. The controls implemented here — lockfile pinning, lifecycle-script suppression, and transitive override governance — map directly to its "Dependency Management" and "Build Integrity" recommendations, and address OWASP Top 10 A06:2021 (Vulnerable and Outdated Components).

## Residual risk / assumptions

- **`ignore-scripts` is advisory, not sandboxed.** pnpm respects this flag, but a build step that explicitly invokes `node node_modules/pkg/postinstall.js` would bypass it. The protection is process-level, not OS-level isolation.
- **The `.npmrc` flag is not enforced at the OS level.** A developer running `pnpm install` on the host without the container-only guard (`scripts/container-only.mjs`) could inadvertently enable lifecycle scripts if their local pnpm configuration overrides the project `.npmrc`.
- **Overrides cover known CVEs only.** The pinned overrides for `devalue` and `yaml` address specific disclosed vulnerabilities; newly disclosed transitive vulnerabilities in other packages (e.g. within `astro`, `sass`, `eslint` chains) are not pre-emptively pinned and would require a manual lockfile update cycle before the CI gate catches them.
- **The CI supply-chain job does not gate the `api-gateway` or `web` Docker builds directly.** It validates that `pnpm install` produces an intact, frozen graph; it does not build or scan the container images themselves. Container-level CVE scanning is handled separately by the `baas-security-scan` Makefile target (Trivy), which is not wired into this specific workflow.
- **The `@grobase/js` SDK is a `file:` path dependency** (`apps/grobase/sdks/js`) — its integrity is not governed by the pnpm lockfile's registry hash mechanism, so its supply-chain assurance depends entirely on the grobase submodule's own controls and the submodule SHA pinned at the root.
