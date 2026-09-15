# SQL Injection

> A class of injection attack in which untrusted input is interpreted as SQL command syntax, allowing an adversary to read, modify, or destroy data in a backend database without authorization.

## What it is

SQL injection exploits the structural ambiguity of SQL: the database engine cannot inherently distinguish between the query a developer wrote and extra SQL that arrived inside a user-supplied value. When an application concatenates raw input directly into a query string, an attacker can close the intended expression early and append arbitrary SQL of their choosing. The vulnerability is language- and framework-agnostic — any tier that builds a SQL string from external input without proper parameterization is potentially at risk. Severity ranges from information disclosure through a single leaky column to full database compromise, authentication bypass, or remote code execution when the database account holds elevated OS privileges. Because the technique requires only HTTP access and is thoroughly documented, SQL injection has remained one of the highest-volume attack classes across three decades of web history.

## How the attack works

1. **Identify an injection point.** The attacker locates a parameter (URL query string, form field, HTTP header, cookie) whose value is reflected in a database query. Error messages, timing differences, or behavioral changes on quote characters confirm that the input reaches raw SQL.

2. **Probe the syntax boundary.** A single apostrophe (`'`) or a comment sequence (`--`, `#`) is submitted. A database error or a changed result set confirms the parameter is interpolated unsafely.

3. **Determine query structure.** Using `ORDER BY` clauses with incrementing column indices, or UNION probes, the attacker maps how many columns the original query returns and which columns are string-typed.

4. **Extract data.** A `UNION SELECT` statement appended to the original query causes the database to return rows from any table the connecting account can read — user credentials, session tokens, PII.

5. **Escalate if possible.** Depending on database permissions, the attacker may write files (`INTO OUTFILE`), read system files (`LOAD_FILE`), or invoke OS commands (`xp_cmdshell` on SQL Server).

**Illustrative (non-weaponized) example — what vulnerable code looks like versus safe code:**

```python
# UNSAFE — user_id is concatenated directly; any string is accepted as SQL
query = "SELECT email FROM users WHERE id = " + user_id

# SAFE — parameterized; the driver separates code from data at the protocol level
cursor.execute("SELECT email FROM users WHERE id = %s", (user_id,))
```

In the unsafe variant, a `user_id` value of `0 UNION SELECT password FROM admins--` would silently redirect the query to return admin password hashes instead of an email address. The parameterized form sends `user_id` as a bound value the database treats exclusively as data, regardless of its content.

## Real-world impact

SQL injection has been documented as a contributing factor in a broad class of government and commercial breaches. Krebs on Security has covered multiple incidents where publicly reachable web properties — including U.S. Department of Defense sites — were found trivially exploitable via SQL injection, exposing backend data to unauthenticated attackers with minimal skill required (reported circa 2011). The Verizon Business RISK team identified SQL injection as one of the dominant attack vectors across the breach corpus they analysed for 2009. The consistent pattern: organizations delayed patching input validation because the fix appeared minor, while the downstream impact included full credential dumps and persistent attacker footholds. Documented impact categories across these incident classes include unauthorized data exfiltration, authentication bypass, and integrity loss through row deletion or modification.

Source: [Krebs on Security — SQL Injection archive](https://krebsonsecurity.com/tag/sql-injection/)

## OWASP classification

SQL injection falls under **OWASP A03:2021 — Injection**, consistently one of the top-ranked risks in every OWASP Top 10 edition since the list's inception. The authoritative mitigation guidance is the **SQL Injection Prevention Cheat Sheet**, which defines four primary defenses (parameterized queries, stored procedures with parameterization, allow-list input validation, and — only as a last resort — escaping) alongside secondary controls around least-privilege database accounts.

Reference: [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)

## How defenders stop it

- **Parameterized queries / prepared statements** — the single most effective control; the database driver enforces code/data separation at the protocol level, making injection structurally impossible regardless of input content.
- **Stored procedures written with bound parameters** — equivalent protection to prepared statements when the procedure itself does not resort to dynamic SQL construction internally.
- **Allow-list validation for structural identifiers** — table names, column names, and sort directions cannot be parameterized in most drivers; map them from a hard-coded set of permitted values rather than reflecting user input.
- **Least-privilege database accounts** — application credentials should grant only the minimum required permissions (e.g., `SELECT` on specific tables); this limits blast radius when a query is compromised.
- **Input validation as a secondary layer** — reject or sanitize inputs that do not conform to expected type, length, and character set before they reach query construction; this is defence-in-depth, not a replacement for parameterization.
- **Disable detailed database error messages in production** — stack traces and SQL syntax errors give attackers free reconnaissance; log internally, return generic errors externally.
- **Web application firewall rules** — detect and block known injection signatures in transit; effective against opportunistic scans though not a substitute for fixing the root cause in application code.
- **Dependency and ORM version hygiene** — keep database drivers and query-builder libraries current; CVEs in these layers can reintroduce injection surface even when application code appears safe.

In this project, see the defenses: [grobase](../defense/grobase/sql-injection.md), [osionos-bridge](../defense/osionos-bridge/sql-injection.md), [platform](../defense/platform/sql-injection.md).

## References

- [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
- [OWASP Community — SQL Injection Attack](https://owasp.org/www-community/attacks/SQL_Injection)
- [Krebs on Security — SQL Injection coverage](https://krebsonsecurity.com/tag/sql-injection/)
