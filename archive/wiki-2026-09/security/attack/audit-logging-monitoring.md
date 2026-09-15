# Security Logging and Monitoring Failures (A09:2021)

> An application fails this category when it does not generate, retain, or act on the security-relevant events needed to detect an ongoing attack, investigate an incident, or satisfy regulatory accountability requirements.

## What it is

Security logging and monitoring failures describe a class of omissions — missing, incomplete, or unmonitored audit trails — that allow intrusions to run unchecked well past their initial foothold. Unlike most vulnerability classes where something is *present* and exploitable, this one is defined by absence: no log entry for a failed authentication burst, no alert when an admin account changes its own permissions, no retention policy keeping evidence past the seven-day rolling window that forensics would need. The failure is not always a blank void; partial logging is equally dangerous — security-irrelevant events flood SIEM storage while the one authentication anomaly that mattered is simply never recorded. OWASP elevated this to ninth place in the 2021 Top 10 partly in response to its consistent appearance in post-incident analyses, where investigators routinely discover that adequate telemetry either was never produced or was collected but never monitored. The category maps to four CWEs: `CWE-117` (improper log output neutralization), `CWE-223` (omission of security-relevant information), `CWE-532` (sensitive data written into logs), and `CWE-778` (insufficient logging).

## How the attack works

1. **Initial access.** An attacker exploits any entry vector — credential stuffing, an injection flaw, a misconfigured endpoint — and establishes a foothold. None of these attempts generate an alert because authentication failures are not logged or the log volume threshold for alerting is never tuned.

2. **Reconnaissance under silence.** The attacker probes internal APIs, reads database schemas, and enumerates user accounts. Because access-control decisions are not emitted as structured events, the SIEM sees no anomaly; the attacker's queries are indistinguishable from legitimate background traffic.

3. **Privilege escalation.** Elevated actions — modifying role assignments, reading backup credentials, disabling security controls — are administrative operations that should fire high-severity events. Without a mandatory audit trail for privileged actions, the escalation is invisible to any monitoring system.

4. **Exfiltration over time.** Data is extracted in small, rate-limited batches to avoid bandwidth-based anomaly detection. Because there is no baseline of normal export volume and no alert on cumulative data egress, the operation continues indefinitely.

5. **Discovery (eventually).** The breach surfaces through an external tip, a downstream victim complaint, or a regulatory inquiry — not through internal detection. By the time anyone looks at logs, the retention window has expired and the forensic record is gone.

**Illustrative example — authentication failure silenced in code:**

```python
# Insecure: exception swallowed, no record of repeated failure
def login(username, password):
    try:
        user = db.query("SELECT * FROM users WHERE username = ?", username)
        if not check_password(user, password):
            return {"error": "invalid credentials"}
    except Exception:
        pass  # Nothing written to any log; a credential-stuffing loop is invisible

# Secure: every outcome is a structured log event
import logging, time

security_log = logging.getLogger("security.auth")

def login(username, password):
    try:
        user = db.query("SELECT * FROM users WHERE username = ?", username)
        if not check_password(user, password):
            security_log.warning(
                "auth_failure",
                extra={"username": username, "ts": time.time(), "ip": request.remote_addr}
            )
            return {"error": "invalid credentials"}
        security_log.info("auth_success", extra={"user_id": user["id"], "ts": time.time()})
        return {"token": issue_token(user)}
    except Exception as exc:
        security_log.error("auth_error", extra={"error": str(exc), "ts": time.time()})
        raise
```

The insecure variant is illustrative only; the difference shown is structural — a silent catch block versus a structured, actionable event stream.

## Real-world impact

The OWASP A09:2021 documentation describes a recurring breach pattern in the healthcare sector: a children's health plan provider suffered unauthorized access to records covering 3.5 million minors, and the intrusion went undetected for a period that investigators later assessed could span more than seven years. The absence of meaningful monitoring meant there was no operational tripwire — no alert on anomalous data-volume reads, no review of after-hours admin sessions, no retained event history that could anchor a timeline. The documented impact category is prolonged unauthorized access to regulated personal data, compounding the harm from a single entry point across years of exposure. This pattern — long dwell time enabled entirely by monitoring absence — is not unique to healthcare; it repeats wherever security events are generated inconsistently and no team owns the alerting pipeline. Source: [A09:2021 Security Logging and Monitoring Failures — OWASP Top 10](https://owasp.org/Top10/2021/A09_2021-Security_Logging_and_Monitoring_Failures/index.html).

## OWASP classification

- **Category:** A09:2021 — Security Logging and Monitoring Failures
- **CWEs:** `CWE-117`, `CWE-223`, `CWE-532`, `CWE-778`
- **Reference:** [A09:2021 — OWASP Top 10](https://owasp.org/Top10/2021/A09_2021-Security_Logging_and_Monitoring_Failures/index.html)
- **Supporting cheat sheet:** [Logging Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)

## How defenders stop it

- **Log the right events as structured data.** Every authentication attempt (success and failure), authorization denial, session lifecycle event, input validation failure, privilege escalation, and access to sensitive records must produce a machine-parseable log entry carrying *when*, *where*, *who*, and *what* — never free-form strings that a parser cannot reliably extract.
- **Never log secrets.** Session tokens, passwords, API keys, encryption material, full payment card numbers, and government identifiers must be excluded or replaced with a non-reversible hash before any log entry is written — logging failures themselves must not create a data-exposure incident (`CWE-532`).
- **Centralize and protect log storage.** Forward events over a secure transport to an append-only, tamper-evident store (SIEM, write-once object storage). Logs that live only on the host being compromised are the first thing an attacker deletes.
- **Define and enforce retention windows.** Security events must be retained long enough to support realistic forensic investigation — typically 90 days hot and 12 months cold; regulatory requirements often mandate longer windows.
- **Alert on anomalies, not just thresholds.** Tune alerts for behavioral anomalies: repeated authentication failures from a single source, privilege changes outside business hours, bulk data reads from a single session, or any event that disables or pauses logging itself.
- **Test the monitoring pipeline.** Regularly generate synthetic security events and verify they flow end-to-end from application to alert. A silent logging misconfiguration is indistinguishable from a quiet week.
- **Normalize event formats.** Use a standard schema — Common Event Format (CEF), JSON with defined field names, or OpenTelemetry log records — so correlation rules and dashboards remain coherent as services evolve.
- **Separate log-write permissions from log-read permissions.** The application account that writes events must not be able to read, modify, or delete its own log stream; administrators who investigate incidents must not share credentials with the pipeline that produces events.

In this project, see the defenses: [grobase](../defense/grobase/audit-logging-monitoring.md), [opposite-osiris](../defense/opposite-osiris/audit-logging-monitoring.md), [auth-gateway](../defense/auth-gateway/audit-logging-monitoring.md), [platform](../defense/platform/audit-logging-monitoring.md).

## References

- [Logging Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- [A09:2021 Security Logging and Monitoring Failures — OWASP Top 10](https://owasp.org/Top10/2021/A09_2021-Security_Logging_and_Monitoring_Failures/index.html)
