# Unrestricted File Upload

> An application accepts user-supplied files without sufficiently validating their type, content, or destination, allowing an attacker to introduce malicious code or data into the server's filesystem.

## What it is

Unrestricted file upload is a vulnerability class in which an application's upload endpoint fails to enforce meaningful constraints on what a user may submit. The server may rely exclusively on client-supplied metadata — a MIME type header or a file extension in the filename string — both of which an attacker trivially controls. When those checks are absent or insufficient, an adversary can upload a file whose content causes harm when stored, served, or processed by the application. The severity is high: a successful exploit can escalate from a single upload endpoint to full remote code execution on the hosting server. The vulnerability is distinct from adjacent issues such as path traversal or XSS, but frequently chains with them to amplify impact.

## How the attack works

1. **Reconnaissance.** The attacker identifies an endpoint that accepts file uploads — a profile-photo form, a document import feature, a support-ticket attachment field — and probes it with boundary cases to map what the server will and will not reject.
2. **Crafting the payload.** The attacker prepares a file whose content is a server-side script (for example, PHP, JSP, or a Node.js module) or an oversized binary intended to exhaust disk or memory. The filename is chosen to pass any naive extension check — for instance, naming a PHP file `avatar.php.jpg` when the server strips only the last extension, or embedding null bytes historically exploited to truncate extension parsing.
3. **Bypassing MIME validation.** If the server reads the HTTP `Content-Type` header, the attacker simply sets it to `image/jpeg` in their request. If the server inspects the file's magic bytes, they prepend valid JPEG header bytes before the script body — many server-side interpreters ignore leading non-script bytes and execute the rest.
4. **Triggering execution.** Once the file lands in a web-accessible directory, the attacker issues an HTTP request directly to its path. If the web server is configured to pass `.php` files (or any aliased extension) to the interpreter, the script runs with the application's process privileges.
5. **Post-exploitation.** A running web shell gives the attacker an interactive command channel: they can read credentials, enumerate internal services, exfiltrate data, or pivot further into the infrastructure.

**Illustrative, non-weaponized example.** Suppose an image-upload handler checks only the file extension client-side in JavaScript and stores the file verbatim under `/var/www/uploads/`:

```php
// Vulnerable pattern — extension check is client-side only; server stores raw
move_uploaded_file($_FILES['photo']['tmp_name'], '/var/www/uploads/' . $_FILES['photo']['name']);
```

An attacker bypasses the front-end check (or sends a raw HTTP request) and uploads `shell.php`. Because `/var/www/uploads/` is within the web root and PHP execution is enabled for that directory, a GET request to `/uploads/shell.php` executes arbitrary server-side code. A safe design would store uploads outside the web root, rename files to a UUID, and serve them through a controller that streams bytes — never executing them.

## Real-world impact

Unrestricted file upload has been the documented entry point in a broad class of web-application compromises where attackers achieved remote code execution by uploading web shells through CMS plugin upload forms, avatar endpoints, or document-import features left unpatched on internet-facing servers. The OWASP Foundation categorises the impact as potentially reaching complete system takeover, denial of service through filesystem exhaustion, and client-side attacks where malicious files are re-served to other users. Content-management platforms and file-sharing services have historically been the most affected categories, with incidents spanning e-commerce, healthcare, and government sectors. Where specific breach details are not independently verifiable, the documented impact category — remote code execution leading to full host compromise — is consistent across multiple OWASP advisories and industry incident reports.

## OWASP classification

OWASP addresses this attack class through two resources:

- **File Upload Cheat Sheet** — the primary defensive reference, covering content validation, storage isolation, execution prevention, and safe filename handling.
  [https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)
- **Unrestricted File Upload (OWASP Community)** — documents the vulnerability's mechanics, severity rating (high likelihood, high impact), and attack vectors including metadata manipulation and content-based exploits.
  [https://owasp.org/www-community/vulnerabilities/Unrestricted_File_Upload](https://owasp.org/www-community/vulnerabilities/Unrestricted_File_Upload)

## How defenders stop it

- **Validate content, not metadata.** Inspect the actual file bytes (magic-number / file-signature check) rather than trusting the `Content-Type` header or the client-supplied filename extension.
- **Allowlist accepted types.** Reject everything that is not explicitly permitted; a denylist of dangerous extensions will always be incomplete.
- **Rename every uploaded file.** Generate a random, opaque identifier (UUID or cryptographic hash) as the stored filename; discard the original name entirely.
- **Store uploads outside the web root.** Files should not be directly reachable via a URL that triggers server-side interpretation. Serve them through an application controller that streams bytes with an explicit, safe `Content-Type`.
- **Strip execute permissions.** The directory receiving uploads should have no execute bit set; the web server should be configured to never interpret files in that location.
- **Enforce size and count limits server-side.** Client-side limits are advisory; validate actual byte counts and per-user upload quotas in the server layer.
- **Scan for malware.** Integrate antivirus or sandboxed analysis for uploads before making them available to other users.
- **Authenticate before accepting uploads.** Unauthenticated upload endpoints dramatically reduce the cost of abuse.
- **Use a CDN or object-store with execution disabled.** Offloading storage to a service such as S3 (with `Block Public ACLs` and no Lambda triggers on the bucket) removes the server-execution vector entirely.

In this project, see the defenses: [osionos](../defense/osionos/file-upload-security.md), [opposite-osiris](../defense/opposite-osiris/file-upload-security.md).

## References

- OWASP Foundation. *File Upload Cheat Sheet*. OWASP Cheat Sheet Series. <https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html>
- OWASP Foundation. *Unrestricted File Upload*. OWASP Community Pages. <https://owasp.org/www-community/vulnerabilities/Unrestricted_File_Upload>
- Ullrich, Johannes B. *8 Basic Rules to Implement Secure File Uploads*. SANS Institute Blog. <https://www.sans.org/blog/8-basic-rules-to-implement-secure-file-uploads/>
