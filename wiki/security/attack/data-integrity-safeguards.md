# Software and Data Integrity Failures

> A class of vulnerabilities where an application blindly trusts code, data, or update payloads it receives without verifying their origin or that they have not been tampered with in transit or at rest.

## What it is

Software and data integrity failures arise whenever a system consumes external artifacts — serialized objects, dependency packages, firmware updates, CI/CD pipeline outputs — without cryptographic proof that those artifacts are genuine and unmodified. The failure is architectural: trust is assumed rather than established. An attacker who can influence any point in the delivery chain — a package registry, an update server, a CDN, or a serialized cookie — gains the ability to inject arbitrary behavior into the target application. The attack surface is unusually broad because it spans the full software supply chain, not just the running application. Historically categorized under insecure deserialization (OWASP 2017), the threat class was broadened in OWASP Top 10:2021 to capture supply-chain and CI/CD scenarios alongside classical deserialization exploits.

## How the attack works

1. **Identify an integrity gap.** The attacker surveys the target for any location where externally-sourced data is consumed without a signature or hash check: a `pickle`/`ObjectInputStream` call on user-supplied input, a software update endpoint that performs no certificate pinning, a CI job that pulls a dependency from a public registry using a mutable floating tag.

2. **Craft a malicious payload.** For deserialization attacks the attacker constructs a gadget chain — a sequence of legitimate classes already present in the classpath whose methods, when invoked in a specific order during deserialization, produce an attacker-controlled side effect such as spawning a subprocess or writing a file. For supply-chain scenarios the attacker publishes a package whose name shadows an internal dependency (dependency confusion) or compromises a package maintainer's credentials to insert malicious code into a legitimate release.

3. **Deliver the payload.** The attacker replaces the legitimate artifact: modifying a serialized session cookie, submitting a crafted HTTP body, pushing a tampered package to a registry, or intercepting an unsigned update download.

4. **Trigger deserialization / import.** The application processes the payload through its normal code path. Because no integrity check precedes processing, the malicious logic executes inside the application's runtime with its existing privileges.

5. **Achieve the objective.** Typical outcomes are remote code execution, privilege escalation within the application, unauthorized access to adjacent datastores, or persistent backdoor installation.

**Illustrative example (non-weaponized):** A Java web application stores the current user's role in a Base64-encoded, Java-serialized cookie. The server calls `ObjectInputStream.readObject()` on the decoded bytes before checking the session. An attacker replaces the cookie with a crafted serialized object that, during reconstruction, invokes `Runtime.exec()` via a publicly documented gadget chain in a bundled version of Apache Commons Collections. No authentication or session validity is required — the exploit fires at the deserialization call itself.

## Real-world impact

The 2020 SolarWinds Orion supply-chain compromise is the canonical documented case for this failure class. Attackers inserted a backdoor — later named SUNBURST — into the official Orion software build pipeline. The tampered update packages were signed with SolarWinds' legitimate certificate and distributed to roughly 18,000 customer organizations through the vendor's standard update mechanism. Because recipients had no independent means to verify the binary's integrity beyond the vendor's own signature infrastructure, the malicious payload reached high-value government and enterprise networks undetected for months. The incident demonstrates that integrity failures extend well beyond application-layer deserialization: the trust boundary encompasses the entire artifact lifecycle from source compilation to endpoint delivery. The impact category — full network compromise at thousands of organizations — is attributed and documented in detail by CISA and the vendor's own post-incident reporting.

Source: [CISA Alert AA20-352A — Advanced Persistent Threat Compromise of Government Agencies, Critical Infrastructure, and Private Sector Organizations](https://www.cisa.gov/news-events/cybersecurity-advisories/aa20-352a)

## OWASP classification

**OWASP Top 10:2021 — A08: Software and Data Integrity Failures**

This category consolidates three mapped weakness families: untrusted code inclusion (`CWE-829`), unsigned download execution (`CWE-494`), and deserialization of untrusted data (`CWE-502`). It replaced the narrower A8:2017 Insecure Deserialization entry to reflect that integrity violations now routinely originate outside the application boundary in dependency and build infrastructure.

Reference: [https://owasp.org/Top10/A08_2021-Software_and_Data_Integrity_Failures/](https://owasp.org/Top10/A08_2021-Software_and_Data_Integrity_Failures/)

Supporting technical detail on the deserialization sub-class: [OWASP Deserialization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html)

## How defenders stop it

- **Sign and verify every artifact.** Apply cryptographic signatures (e.g., GPG, Sigstore/cosign) to packages, container images, and update bundles; verify the signature *before* loading or executing the artifact, not after.
- **Lock dependency versions with hash pinning.** Use lockfiles that record the exact content hash of every resolved dependency (`package-lock.json`, `Cargo.lock`, `go.sum`). Floating version ranges (`^`, `~`, `>=`) permit silent substitution.
- **Never deserialize untrusted data with native mechanisms.** Prefer schema-constrained data formats (JSON with strict validation, Protocol Buffers) over language-native serialization (`pickle`, `ObjectInputStream`, `BinaryFormatter`). Where native deserialization is unavoidable, enforce a narrow allowlist of permitted classes before invoking the deserializer.
- **Integrity-check serialized session state.** HMAC-sign any serialized data stored client-side. Reject payloads whose signature does not match before touching the bytes.
- **Enforce CI/CD pipeline integrity.** Pin action versions to their commit SHA in GitHub Actions; restrict who can modify pipeline definitions; run build steps in ephemeral, least-privilege containers; generate and verify a Software Bill of Materials (SBOM) for each release artifact.
- **Use vetted, mirrored repositories.** Proxy public package registries through an internal mirror that applies malware scanning and provenance checks; configure scoped registries so internal package names cannot be shadowed by public ones (dependency confusion mitigation).
- **Monitor deserialization call sites at runtime.** Use RASP agents or Java agents (e.g., `SerialKiller`, `NotSoSerial`) to intercept and block deserialization of classes not on the application allowlist.
- **Keep serialization libraries current.** Many gadget chains rely on known-vulnerable versions of common utility libraries. CVE tracking and automated dependency updates close these windows.

In this project, see the defenses: [platform](../defense/platform/data-integrity-safeguards.md)

## References

- [OWASP Top 10:2021 — A08: Software and Data Integrity Failures](https://owasp.org/Top10/A08_2021-Software_and_Data_Integrity_Failures/)
- [OWASP Deserialization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html)
- [PortSwigger Web Security Academy — Insecure Deserialization](https://portswigger.net/web-security/deserialization)
- [CISA Advisory AA20-352A — SolarWinds Supply Chain Compromise](https://www.cisa.gov/news-events/cybersecurity-advisories/aa20-352a)
