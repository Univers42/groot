# Supply-Chain Security — grobase (the BaaS backend)

> Every edge container grobase ships is built from a minimal, controlled base, with upstream binaries verified by SHA-256 digest before installation, and run as a dedicated unprivileged user — so a tampered upstream package or a compromised image tag cannot introduce an undetected backdoor or a root-level process.

## What it is (the concept)

**Software supply-chain security** is the set of controls that prevent an attacker from injecting malicious code into software by compromising an upstream dependency, package mirror, or base image — rather than attacking the application itself. The two load-bearing mechanisms are **integrity verification** (confirming that what was downloaded matches a known-good hash) and **least-privilege execution** (running processes as a non-root user so a compromised component cannot own the host). A third reinforcing layer is **attack-surface reduction**: stripping build-time tools, scripting runtimes, and unnecessary modules from the final image so they cannot be weaponised even if a vulnerability exists in them.

## What it defends against

See [Software Supply Chain Attack](../../attack/supply-chain-security.md).

In the grobase context, the two highest-risk points are the **Kong API gateway** (all BaaS traffic routes through it) and the **WAF** (the TLS-terminating public entry point). A tampered binary slipped into either container at build time could intercept every tenant request, exfiltrate credentials, or pivot into the internal `mini-baas` Docker network. Running either service as root would additionally allow a container-escape to inherit host privileges. The controls below address both vectors at image-build time, before a single byte of tenant traffic is processed.

## How grobase implements it

### Kong gateway — SHA-256-pinned `.deb` + UID assertion + `USER kong`

`apps/grobase/infra/docker/services/kong/Dockerfile` does not pull a pre-built `kong:3.8` vendor image. Instead it installs the official Kong Debian package onto `debian:bookworm-slim` (a base the project controls) and verifies the download before installation:

```dockerfile
ARG KONG_SHA256=3eca0f8f72d923f8a20c68ad5c2abce3360e1a8d796571b2562ffa66be06702c
...
curl -fL "${DOWNLOAD_URL}" -o /tmp/kong.deb; \
echo "${KONG_SHA256}  /tmp/kong.deb" | sha256sum -c -; \
apt-get install -y --no-install-recommends /tmp/kong.deb; \
```

The `sha256sum -c -` call exits non-zero if the digest does not match, which causes `docker build` to abort — the image cannot be built with a tampered package. After installation, a build-time assertion enforces that the `.deb` created `kong` at exactly UID 1000:

```dockerfile
[ "$(id -u kong)" = "1000" ] || { echo "FATAL: kong uid != 1000 (got $(id -u kong))"; exit 1; }
```

The final directive is `USER kong`, so the gateway process runs unprivileged and no subsequent layer can silently regress to root.

### WAF (ModSecurity + OWASP CRS) — pinned dated tag + aggressive surface reduction + `USER nginx`

`apps/grobase/infra/docker/services/waf/Dockerfile` pins the CRS upstream image to a specific timestamped build rather than a floating tag:

```dockerfile
FROM owasp/modsecurity-crs:4-nginx-202604040104 AS waf_runtime
```

This prevents a `latest`-style tag from silently swapping the image on a re-pull. On top of that base, the Dockerfile aggressively strips every component not needed at runtime — development headers, curl, all Perl packages (`libperl5.40`, `perl-modules-5.40`, `perl-base`), GeoIP and image-processing nginx modules, NJS, fonts, and Java artifacts — in a single `RUN` layer so nothing leaks into the image. Configuration files are written with restrictive permissions (`--chmod=0444` for nginx config, `--chmod=0644` for ModSecurity config). The final stage is `FROM scratch` with `COPY --from=waf_runtime / /`, discarding any residual image metadata, and closes with `USER nginx`.

### Dependency CVE scanning — `cargo-audit` + `govulncheck`

`apps/grobase/scripts/security/audit-deps.sh` runs two reachability-based scanners against the project's own dependency trees:

- **Rust data plane** (`src/data-plane-router`): `cargo-audit` checks every crate against the RustSec advisory database and exits non-zero on any new unacknowledged advisory.
- **Go control plane** (`src/control-plane`): `govulncheck` performs reachability analysis — it reports only vulnerabilities in code paths that are actually called, suppressing noise from unused transitive dependencies.

Both scanners run fully containerised (the same Rust and Go toolchain images used for builds), with no host toolchain required.

### Container SAST — Semgrep `p/dockerfile` ruleset

`apps/grobase/scripts/security/run-security-scans.sh` runs Semgrep with the `p/dockerfile` ruleset, which includes the `dockerfile.security.missing-user` rule — the rule that would flag any image whose final stage lacks a `USER` directive. Kong and WAF both satisfy this rule, as does the comment in the Kong Dockerfile that explicitly names it: `"semgrep dockerfile.security.missing-user does not flag the image, and no later layer can regress to root"`.

## How we know it is applied

**Build-time enforcement (cannot be bypassed):** The `sha256sum -c -` line and the `id -u kong` assertion are inside the `RUN` instruction that installs Kong. If either check fails, `docker build` exits non-zero and no image is produced — the control cannot be skipped without editing the Dockerfile.

**Compose wiring confirms these are the actual build contexts.** `apps/grobase/orchestrators/compose/base/gateway.yml` maps both services to their Dockerfiles:

```yaml
waf:
  build:
    context: ./infra/docker/services/waf   # → waf/Dockerfile

kong:
  build:
    context: ./infra/docker/services/kong  # → kong/Dockerfile
```

**Operator-runnable supply-chain scan gate.** `make audit-deps` (defined in `apps/grobase/orchestrators/makes/20-stack.mk`, line 150) invokes `scripts/security/audit-deps.sh` and exits non-zero on any new unacknowledged CVE:

```
audit-deps: ## Supply-chain CVE scan — cargo-audit (Rust) + govulncheck (Go)
    @bash scripts/security/audit-deps.sh
```

**Full SAST + container scan.** `make baas-security-scan` (defined in `infrastructure/makes/baas-verify.mk`, line 246) invokes `run-security-scans.sh` with Semgrep (`p/owasp-top-ten p/dockerfile`), Trivy image scan, and TruffleHog secrets scan, all in Docker with no host install.

## Reference

The [OWASP Software Supply Chain Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html) defines the authoritative controls for verifying the integrity of third-party components, pinning dependency versions, and enforcing least-privilege execution in build pipelines. Grobase's implementation addresses the cheat sheet's top priorities — base-image integrity, build-time verification, and attack-surface reduction — through Dockerfile-level enforcement rather than advisory tooling alone, meaning violations fail the build rather than generating a report that can be ignored.

A corroborating reference: SLSA (Supply-chain Levels for Software Artifacts) level 2 requires provenance and build integrity — the SHA-256 check on the Kong `.deb` is the minimal implementation of that requirement for an externally sourced binary.

## Residual risk / assumptions

- **WAF image tag is pinned by date, not by digest.** `owasp/modsecurity-crs:4-nginx-202604040104` is a specific build tag, not an `@sha256:…` digest pin. If the upstream registry were to rewrite that tag (unlikely for a timestamped tag but not impossible), the integrity guarantee would not catch it. A digest pin in `FROM` would close this.
- **Kong SHA is hardcoded for `amd64`.** The `KONG_SHA256` ARG matches `kong_3.8.0_amd64.deb` specifically. A build on an ARM host would need a separate SHA for the `arm64` package; the current Dockerfile does not handle multi-arch.
- **`cargo-audit` and `govulncheck` are operator-triggered, not enforced in CI.** The `make audit-deps` target exists and exits non-zero on new findings, but the grobase CI workflow (`.github/workflows/ci.yml`) does not invoke it automatically. A new transitive advisory introduced between manual runs would not block a merge.
- **The `FROM scratch` WAF final stage** strips image metadata but cannot remove vulnerabilities that were already compiled into the binary layer copied from `waf_runtime`. Trivy image scanning is the compensating control for those.
- **No SBOM is generated or attested.** The build process does not produce a signed Software Bill of Materials. Downstream consumers cannot verify the composition of the produced images without re-running the build themselves.
