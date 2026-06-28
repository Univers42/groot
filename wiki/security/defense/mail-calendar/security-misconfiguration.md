# Security Misconfiguration — mail and calendar (Google OAuth apps)

> Both bridges enforce a **configured()** guard that hard-disables the OAuth flow when credentials are absent, and the calendar stack binds its exposed ports to loopback only, shrinking the network attack surface.

---

## What it is (the concept)

**Security Misconfiguration** occurs when a system's default, incomplete, or inconsistent settings open an unintended attack surface — for example, an OAuth integration that begins a redirect flow even though no client credentials have been supplied, or a development service that inadvertently listens on all network interfaces. The **principle of least privilege** and **fail-closed defaults** are the canonical mitigations: a missing credential or wrong binding should make the system do less, not more. **Fail-closed** means that an unconfigured feature returns an explicit error instead of silently proceeding in a degraded or insecure state.

---

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

In the mail and calendar context the threat takes two forms. First, if `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET` are left blank (the shipping default), a naive implementation could still redirect the user's browser to Google, creating a confusing half-initialized flow that leaks the redirect URI and misleads the user into an integration that cannot complete. Second, if bridge or app ports are published on all network interfaces, any peer on the same LAN or VirtualBox host-only network can reach endpoints that hold or exchange OAuth tokens.

---

## How mail-calendar implements it

### Fail-closed OAuth guard

Both bridge servers define an identical `configured()` predicate that returns `false` whenever either credential variable is falsy:

`apps/mail/bridge/server.mjs` (line 200–201):
```js
function configured() {
  return Boolean(googleClientId && googleClientSecret);
}
```

`apps/calendar/bridge/server.mjs` (line 169–170) contains the same two-line function verbatim.

The sole entry point to the OAuth redirect in each bridge checks this predicate before doing anything else:

`apps/mail/bridge/server.mjs` (line 757–761) — `startGmailAuth`:
```js
function startGmailAuth(response) {
  if (!configured()) {
    json(response, 400, publicSession());
    return;
  }
```

`apps/calendar/bridge/server.mjs` (line 606–609) — `startGoogleAuth`:
```js
function startGoogleAuth(response) {
  if (!configured()) {
    publicSession().then((session) => json(response, 400, session));
    return;
  }
```

Neither branch falls through to `randomBytes` (state generation) or the Google redirect URL when credentials are absent; the connection is rejected before any OAuth artefact is created.

The shipped template `apps/mail/.env.example` (lines 38–43) explicitly leaves both variables blank and documents the intent:

```
# OPTIONAL: Optional. Leave empty to disable the integration and gain a smaller local attack surface.
# Optional. Google OAuth client ID used by Mail and Calendar bridges. If omitted: Gmail connection is disabled until credentials are provided.
GOOGLE_CLIENT_ID=

# Optional. Google OAuth client secret used by Mail and Calendar bridges. If omitted: Gmail connection is disabled until credentials are provided.
GOOGLE_CLIENT_SECRET=
```

The default deployment state is therefore "Google integration off" — opt-in, not opt-out.

### Loopback port binding (calendar)

`apps/calendar/docker-compose.yml` publishes both the calendar app and its bridge exclusively to the loopback address:

```yaml
# line 21 — calendar app
ports:
  - "127.0.0.1:3003:3003"

# line 55 — calendar-bridge (holds OAuth tokens)
ports:
  - "127.0.0.1:4200:4200"
```

Docker interprets the `host-ip:host-port:container-port` triplet literally: it binds the host-side socket to `127.0.0.1` only, so no packet from an external interface can reach either service.

---

## How we know it is applied

**OAuth guard — runtime path:** `startGmailAuth` and `startGoogleAuth` are the only routes that initiate Google OAuth in their respective bridges (confirmed by reading the full route dispatch tables in each `server.mjs`). Both guard functions are positioned as the very first statement of the route handler, so there is no code path that reaches the redirect construction without passing the `configured()` check.

**Loopback binding — compose wiring:** Docker publishes ports from the compose file at container start. The `127.0.0.1:` prefix on both `ports` entries in `apps/calendar/docker-compose.yml` means the kernel-level socket is bound to loopback at the moment the calendar stack starts — no application code is needed to enforce it.

**Contrast with mail:** `apps/mail/docker-compose.yml` (lines 13 and 38) publishes its ports without a host-IP prefix (`${MAIL_HOST_PORT:-3002}:3002`, `${MAIL_BRIDGE_PORT:-4100}:4100`), so the mail bridge listens on all interfaces in the default configuration. The loopback control is calendar-specific; the mail bridge relies on network-level controls outside the compose file (firewall, VirtualBox NAT, or the root compose network) for equivalent isolation.

---

## Reference

**A05:2021 Security Misconfiguration — OWASP Top Ten**
<https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/>

The OWASP category explicitly calls out "unnecessary features are enabled or installed" and "default accounts and passwords still enabled and unchanged" as the primary failure modes. The `configured()` guard directly addresses the first point by collapsing the enabled feature set to zero when no credentials are present, and the loopback binding addresses the implicit second point by eliminating unnecessary network exposure in the calendar stack.

---

## Residual risk / assumptions

- **Mail ports are unguarded at the compose level.** `apps/mail/docker-compose.yml` does not bind to loopback, so `mail` (port 3002) and `mail-bridge` (port 4100) are reachable from any interface the Docker daemon exposes — protection depends on host firewall rules or the container network topology, neither of which is enforced in this repo.
- **The `configured()` check is not tested.** There are no automated unit or integration tests in `apps/mail/` or `apps/calendar/` that assert HTTP 400 is returned when credentials are absent; the control is verified only by code reading, not by a CI gate.
- **Credential injection via environment.** Once `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are set, `configured()` returns `true` unconditionally — the values are trusted as-is. There is no runtime validation that they are well-formed OAuth 2.0 credentials; a typo does not trigger the guard and will instead cause a downstream error from Google.
- **Token file at rest.** Both bridges persist OAuth tokens to a file on the container filesystem (`tokenFile`). The `configured()` guard protects the auth-start route but does not restrict read access to the token file itself; container filesystem access controls and volume permissions govern that boundary.
