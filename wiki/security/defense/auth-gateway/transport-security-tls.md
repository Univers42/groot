# Transport Security (TLS) — auth-gateway (the auth BFF)

> The auth-gateway enforces verified TLS on every outbound SMTP connection and sanitizes email headers to prevent injection, ensuring auth emails cannot be intercepted or manipulated in transit.

## What it is (the concept)

**Transport Layer Security (TLS)** is a cryptographic protocol that authenticates the remote endpoint and encrypts the channel, preventing passive eavesdropping and active tampering. **Certificate verification** (`rejectUnauthorized: true`) is the critical property: a TLS handshake that does not validate the server certificate against a trusted CA is trivially MITM-able regardless of encryption. **STARTTLS** is a protocol upgrade mechanism that begins a plaintext connection and then promotes it to TLS before any sensitive data — credentials or message body — is exchanged. **SMTP header injection** (also **CRLF injection**) is a complementary control: un-sanitized `\r\n` sequences in envelope fields let an attacker append rogue headers or split messages.

## What it defends against

See [Man-in-the-Middle & Protocol Downgrade](../../attack/transport-security-tls.md).

In the auth-gateway context the threat is concrete: the gateway sends authentication-critical emails — account-verification links, password-reset tokens, and login alerts — over SMTP. An attacker who can intercept that channel (e.g., a rogue relay on the container network) and present a forged certificate would silently capture those one-time tokens if `rejectUnauthorized` were left `false`. A CRLF injection in the configured `SMTP_FROM_NAME` or `SMTP_FROM_ADDRESS` could add arbitrary headers to messages handled by the same SMTP session.

## How auth-gateway implements it

Three cooperating mechanisms are implemented in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs):

**1. Explicit TLS socket with mandatory certificate verification**

`connectTlsSmtpSocket` (line 622) wraps Node's `tls.connect` and hard-codes `rejectUnauthorized: true` in both call paths — direct TLS (implicit SSL/SMTPS) and the STARTTLS upgrade over an existing plain socket:

```js
// lines 624-626
const options = existingSocket
  ? { socket: existingSocket, host: config.smtpHost, servername: config.smtpHost, rejectUnauthorized: true }
  : { host: config.smtpHost, port: config.smtpPort, servername: config.smtpHost, rejectUnauthorized: true };
```

`servername` is always set to `config.smtpHost` so SNI is correct and the certificate CN/SAN check resolves against the intended hostname, not the socket's IP.

**2. STARTTLS upgrade path**

`sendSmtpMail` (line 642) uses `config.smtpEncryption` — derived from the `SMTP_ENCRYPTION` / `SMTP_SECURE` environment variable via `normalizeSmtpEncryption` (line 41) — to branch behaviour. When `smtpEncryption === 'starttls'`, it issues the `STARTTLS` command (line 655) and immediately promotes the socket by calling `connectTlsSmtpSocket` on the existing connection (line 656), re-issuing `EHLO` over the encrypted channel before any AUTH or DATA:

```js
// lines 654-658
if (config.smtpEncryption === 'starttls') {
    await client.send('STARTTLS', [220]);
    socket = await connectTlsSmtpSocket(client.socket);
    client = createSmtpClient(socket);
    await client.send('EHLO prismatica.local', [250]);
}
```

**3. SMTP header injection guard (CRLF stripping)**

`smtpBody` (line 529) sanitizes operator-controlled envelope fields before they are written into the raw SMTP DATA block. `fromName` has every `\r` replaced with a space and every `\n` replaced with a space; `fromAddress` has both stripped entirely:

```js
// lines 530-531
const fromName    = config.smtpFromName.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
const fromAddress = config.smtpFromAddress.replaceAll('\r', '').replaceAll('\n', '').trim();
```

**Runtime wiring**

The compose service definition at [`docker-compose.yml`](../../../../docker-compose.yml) line 356 passes `SMTP_ENCRYPTION` as `${SMTP_ENCRYPTION:-none}` (defaulting to Mailpit plaintext in dev). The image built by [`apps/opposite-osiris/docker/services/api-gateway/Dockerfile`](../../../../apps/opposite-osiris/docker/services/api-gateway/Dockerfile) copies `auth-gateway.mjs` verbatim into the runtime image and starts it with `node scripts/auth-gateway.mjs` (line 55), so there is no transformation between the reviewed source and the running process.

## How we know it is applied

The control is live on every code path that sends email. `sendSmtpMail` is the single SMTP egress function in the file and is called by every email handler (register, newsletter-welcome, newsletter-unsubscribe, and the remaining auth flows). Because `connectTlsSmtpSocket` is the only function in the file that opens a TLS socket, and it always passes `rejectUnauthorized: true`, there is no alternative code path that could bypass certificate verification for SMTP.

The Dockerfile's `HEALTHCHECK` (line 52-53) and the matching compose `healthcheck` (docker-compose.yml line 382) confirm the gateway is running the same script:

```dockerfile
CMD node -e "fetch('http://127.0.0.1:8787/api/auth/availability')\
  .then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
```

Compose waits for this probe to pass before marking the service healthy, so any startup failure — including a misconfigured `tls` module — surfaces before dependents come up.

## Reference

The [Transport Layer Security Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html) defines the minimum acceptable configuration for TLS in server-to-server communication, including the requirement for full certificate chain validation and the prohibition on disabling hostname verification. The auth-gateway implementation satisfies both requirements for its SMTP channel through the hard-coded `rejectUnauthorized: true` and explicit `servername` fields.

## Residual risk / assumptions

- **Dev default is plaintext.** `SMTP_ENCRYPTION` defaults to `none` in `docker-compose.yml`, so local Mailpit traffic is unencrypted. This is intentional for development convenience but means the TLS control is only active when a production SMTP relay is configured with `SMTP_ENCRYPTION=ssl` or `SMTP_ENCRYPTION=starttls`.
- **No inbound TLS at the gateway itself.** The gateway listens on plain HTTP port 8787 inside the Docker network; TLS termination for inbound browser traffic is handled upstream by the `local-https-proxy` container. If that proxy were removed or misconfigured, the path from browser to gateway would be unencrypted inside the compose network.
- **CA trust is the system CA bundle.** `rejectUnauthorized: true` delegates chain validation to Node's bundled CA store (the `node:22-alpine` base image). A compromised or mis-issued certificate from a CA in that bundle would pass verification.
- **`to:` and `subject:` fields are not sanitized.** The CRLF guard covers `fromName` and `fromAddress` only. The `to` and `subject` values passed into `smtpBody` originate from application logic (not raw user input in these flows), but they receive no explicit strip in `smtpBody` itself.
- **SMTP credentials transit in-process memory.** `SMTP_USERNAME` and `SMTP_PASSWORD` are loaded from environment variables at startup and held in `config`. They are transmitted over the TLS channel via `AUTH LOGIN` (base64-encoded, not encrypted at the application layer — TLS provides the confidentiality).
