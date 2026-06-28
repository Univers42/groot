# Multi-Stage Intrusion / Layered Attack

> An adversary defeats isolated security controls one at a time, chaining small footholds into full system compromise — precisely what a defense-in-depth architecture is designed to stop.

## What it is

A multi-stage intrusion is an attack class in which the adversary advances through a target environment in sequential, deliberate phases rather than exploiting a single vulnerability and walking away. Each stage expands the attacker's access or persistence and lays the groundwork for the next, so the full impact only becomes visible once several independent controls have each failed. The technique exploits the architectural assumption that perimeter defenses are sufficient — an assumption that collapses the moment any one boundary is crossed. Because each individual action can appear benign in isolation (a credential lookup, a lateral network call, a scheduled task), multi-stage campaigns are notoriously difficult to detect without correlated, cross-layer visibility. The attack class encompasses well-known kill-chain patterns including supply-chain compromise, living-off-the-land (LotL) lateral movement, and advanced persistent threat (APT) campaigns.

## How the attack works

1. **Initial access** — The attacker obtains a foothold through a low-privileged entry point: phishing, a vulnerable public-facing service, or third-party credentials. The compromise may be limited to a single non-production host or an unprivileged service account.
2. **Persistence and reconnaissance** — Lightweight implants or abused built-in tooling (scheduled tasks, cron jobs, legitimate admin utilities) establish persistence. The attacker surveys internal network topology, service accounts, and trust relationships without yet touching sensitive data.
3. **Privilege escalation** — Misconfigurations, unpatched local vulnerabilities, or overly-broad IAM grants let the attacker step up from a low-privilege process to a database user, admin account, or container escape.
4. **Lateral movement** — Using harvested credentials or forged tokens, the attacker pivots from the initial beachhead to adjacent systems — crossing network segments that should be isolated but are not adequately enforced.
5. **Objective execution** — Having reached the target asset (PII store, payment system, secret vault), the attacker exfiltrates data, deploys ransomware, or plants a backdoor for future re-entry.

**Illustrative example (non-weaponized):** An attacker compromises a contractor's VPN credentials through credential stuffing. The contractor account has read access to an internal file share. From the file share, the attacker retrieves a plaintext database password left in a configuration file. That password grants access to a production replica with no network segmentation between it and the primary. The attacker stages an exfiltration over an allowed outbound port (e.g., `443`) to a cloud storage bucket. At no single step does the attacker need a zero-day — only the absence of layered controls.

## Real-world impact

The 2013 Target retail breach is one of the most-studied examples of multi-stage intrusion through a trusted third party. Attackers obtained network credentials from an HVAC contractor, pivoted through vendor-accessible systems, and ultimately reached point-of-sale devices across thousands of stores — resulting in roughly 40 million payment card numbers being stolen. The core failure was not a missing antivirus signature but an architectural one: vendor access was not segmented from payment infrastructure, so a single compromised supplier account became a path to the most sensitive assets in the environment. Brian Krebs documented the breach mechanics in detail shortly after the public disclosure (see References).

## OWASP classification

This attack class is addressed under the **Defense-in-Depth** security principle in the OWASP Secure Product Design Cheat Sheet. OWASP frames defense-in-depth as the layering of multiple independent security controls so that the failure of any one layer does not directly expose the protected asset — the exact property that multi-stage intrusions exploit when it is absent.

Reference: [Secure Product Design — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Secure_Product_Design_Cheat_Sheet.html)

## How defenders stop it

- **Network segmentation and micro-segmentation** — enforce least-privilege network paths between services; vendor and third-party access must never share a network segment with sensitive production systems.
- **Zero-trust architecture** — authenticate and authorize every request independently of network location; never trust an internal IP or a previously established session implicitly.
- **Secrets hygiene** — never store credentials, tokens, or keys in configuration files, environment dumps, or version control; rotate them regularly and audit access.
- **Privilege minimization** — service accounts, API tokens, and human accounts receive only the permissions required for their specific function; no shared admin credentials.
- **Multi-layer logging and correlation** — collect and correlate events across network, host, and application planes; a single anomalous event is noise, but correlated anomalies across layers are signal.
- **Immutable, audited infrastructure** — containers and VMs rebuilt from signed images limit persistence options; runtime integrity monitoring detects unexpected process or file changes.
- **Patch cadence on all layers** — perimeter, host, runtime, and dependency vulnerabilities are each an individual rung an attacker can climb; all layers require timely patching.
- **Third-party risk management** — vendor and contractor access is scoped, time-limited, and monitored; supply-chain credentials are treated with the same rigor as privileged internal accounts.

In this project, see the defenses: [grobase](../defense/grobase/defense-in-depth.md).

## References

- [Secure Product Design Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Secure_Product_Design_Cheat_Sheet.html)
- [Target Hackers Broke in Via HVAC Company — KrebsOnSecurity, February 2014](https://krebsonsecurity.com/2014/02/target-hackers-broke-in-via-hvac-company/)
