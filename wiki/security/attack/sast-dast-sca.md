# Vulnerable and Outdated Components

> The practice of shipping or running software that contains known security defects in its third-party libraries, frameworks, operating system packages, or container base images — creating exploitable attack surface that is already documented in public vulnerability databases.

## What it is

Every modern application is built on a stack of dependencies: language runtimes, web frameworks, ORM layers, authentication libraries, container base images, and transitive packages pulled in by each of those. When any layer in that stack carries a publicly disclosed vulnerability — catalogued in the NVD/CVE database or a vendor advisory — an attacker does not need to discover the flaw; the work is already done for them. The attack class therefore requires no novel research: the attacker only needs to identify which version of a component is running and match it against a known-vulnerable range. This makes exploitation cheap, scalable, and automatable. The risk is compounded by transitive dependencies: a project may audit its direct dependencies carefully while an indirect dependency three levels deep quietly accumulates critical CVEs. Continuous Software Composition Analysis (SCA) — scanning dependency graphs against advisory feeds — is the standard control because point-in-time audits decay the moment a new CVE is published.

## How the attack works

1. **Reconnaissance.** The attacker probes the target for version signals: HTTP response headers (`X-Powered-By`, `Server`), JavaScript bundle filenames that embed a version string, `/package.json` or `/composer.json` left publicly accessible, or error pages that leak framework names.
2. **Vulnerability matching.** The identified version is cross-referenced against public databases (NVD, GitHub Advisory Database, OSV) to find a CVE with a working proof-of-concept or Metasploit module.
3. **Payload delivery.** The attacker sends a crafted request that exercises the known code path — a malformed multipart upload, a specially encoded query parameter, a deserialization payload — without needing any authentication if the vulnerable endpoint is public.
4. **Post-exploitation.** Depending on the CVE's impact class, the attacker achieves remote code execution, authentication bypass, sensitive data disclosure, or denial of service.

**Illustrative example.** A Node.js API runs `express-fileupload@1.1.7-alpha.4`, a version known to be vulnerable to prototype pollution (`CVE-2020-7699`). An attacker sends a crafted multipart body that injects properties onto `Object.prototype`. Downstream code that iterates object keys without `hasOwnProperty` guards begins behaving unexpectedly, potentially enabling arbitrary property injection or — in the right execution context — remote code execution. No knowledge of the application's own source code is required; the exploit targets the library in isolation.

```http
POST /upload HTTP/1.1
Content-Type: multipart/form-data; boundary=----Boundary

------Boundary
Content-Disposition: form-data; name="__proto__[admin]"

true
------Boundary--
```

This is an illustrative, non-weaponized sketch — not a working exploit against any live system.

## Real-world impact

The 2017 Equifax breach is the canonical example of this attack class. Equifax ran a public-facing web portal backed by Apache Struts, a Java web framework. On 8 March 2017, Apache released patches and advisories for `CVE-2017-5638`, a critical remote code execution flaw in Struts' multipart request parser. Public proof-of-concept exploit code appeared within days. Equifax did not apply the patch. Attackers exploited the unpatched endpoint beginning in May 2017; the company did not detect the intrusion until late July — more than four months after a fix was freely available. The breach ultimately exposed personal and financial records belonging to approximately 143 million US consumers. The technical root cause was a single unpatched library version; the organisational root cause was the absence of a systematic patch management and SCA process. (Source: Krebs on Security, September 2017 — <https://krebsonsecurity.com/2017/09/equifax-hackers-stole-200k-credit-card-accounts-in-one-fell-swoop/>)

## OWASP classification

This attack class maps to **OWASP Top 10:2021 — A06: Vulnerable and Outdated Components**. It ranked second in the 2021 community survey, reflecting how pervasive the problem remains across the industry. OWASP characterises it through three primary CWEs, with an observed incidence rate averaging 8.77% across surveyed applications.

Reference: <https://owasp.org/Top10/2021/A06_2021-Vulnerable_and_Outdated_Components/index.html>

For CI/CD pipeline controls specifically — dependency pinning, lock-file enforcement, SCA gate integration, and supply-chain integrity verification — see the **OWASP CI/CD Security Cheat Sheet**: <https://cheatsheetseries.owasp.org/cheatsheets/CI_CD_Security_Cheat_Sheet.html>

## How defenders stop it

- Maintain a complete, continuously updated software bill of materials (SBOM) covering both direct and transitive dependencies across all services, runtimes, and container layers.
- Integrate SCA tooling (`trivy`, `grype`, `osv-scanner`, `npm audit`, `govulncheck`) as a blocking step in CI — fail the pipeline on CVEs above your defined severity threshold.
- Pin dependencies to exact versions using lock files (`package-lock.json`, `go.sum`, `Cargo.lock`) and validate lock-file integrity by hash; never resolve to `latest` in production builds.
- Subscribe to upstream advisory feeds (GitHub Advisory Database, OSV, NVD) and triage new CVEs against your SBOM within a defined SLA (e.g., critical: 24 h, high: 7 days).
- Apply virtual patching at the WAF or network layer for critical CVEs in unmaintainable components while a proper upgrade is prepared — not as a permanent substitute.
- Replace unmaintained or abandoned libraries; track upstream EOL dates for languages, runtimes, and base images the same way you track OS EOL.
- For container images, use minimal base images (`distroless`, `alpine`) and rebuild on every upstream patch to inherit OS-level fixes automatically.
- In CI/CD pipelines, prefer private package registries with scoped package controls to mitigate dependency confusion and typosquatting attacks that piggyback on this class.

In this project, see the defenses: [platform](../defense/platform/sast-dast-sca.md).

## References

- OWASP Top 10:2021 — A06 Vulnerable and Outdated Components: <https://owasp.org/Top10/2021/A06_2021-Vulnerable_and_Outdated_Components/index.html>
- OWASP CI/CD Security Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/CI_CD_Security_Cheat_Sheet.html>
- Krebs on Security — "Equifax Hackers Stole 200k Credit Card Accounts in One Fell Swoop" (September 2017): <https://krebsonsecurity.com/2017/09/equifax-hackers-stole-200k-credit-card-accounts-in-one-fell-swoop/>
