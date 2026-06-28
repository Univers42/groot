# WebAuthn Passkey Registration — osionos (the block editor)

> osionos lets authenticated users register FIDO2/WebAuthn passkeys through the settings UI; the private key never leaves the authenticator, and the bridge stores only the credential ID, public key, and transports.

## What it is (the concept)

**WebAuthn** (Web Authentication, FIDO2) is a W3C standard that replaces or supplements passwords with **public-key cryptography bound to an authenticator** (hardware security key, platform TPM, Face ID, Windows Hello, etc.). The browser mediates the ceremony: it calls `navigator.credentials.create()` for registration and `navigator.credentials.get()` for assertion, enforcing **origin binding** so the credential cannot be replayed against a different domain. A **passkey** is a discoverable WebAuthn credential stored by the platform authenticator and usable without a username prompt. The `attestation` forwarded to the server contains only the **public key and credential ID** — the private key is created and stored exclusively inside the authenticator hardware or TPM.

## What it defends against

See [Credential Phishing & Password-Based Account Takeover](../../attack/mfa-passkeys.md).

In the osionos context the specific threats are: an attacker who has obtained a user's password through a phishing site or data breach cannot authenticate, because the WebAuthn assertion is cryptographically bound to `https://localhost` (or the deployed origin). A rogue site that mimics the osionos domain cannot trigger a valid assertion for the real origin. The control also neutralises credential-stuffing: there is no reusable shared secret to stuff.

## How osionos implements it

The implementation spans two files in `apps/osionos/app/`:

**`src/features/settings/SettingsCenter.tsx`** — the account security panel mounts an "Add passkey" button whose click handler drives the full registration ceremony:

```ts
// line 17 — static import; @simplewebauthn/browser^13.3.0 in package.json
import { startRegistration } from '@simplewebauthn/browser';

// lines 680-687
async function handleRegisterPasskey(nickname = 'osionos passkey') {
  const options = await registerPasskeyOptions(nickname);
  const response = options
    ? await startRegistration({ optionsJSON: options as ... })
    : { id: `local-${Date.now()}`, response: { transports: ['internal'] } };
  await verifyPasskeyRegistration(response, nickname);
  toast({ kind: 'success', title: 'Passkey added' });
}
```

When the bridge is reachable (`options` is non-null), `startRegistration()` invokes the platform authenticator via the browser WebAuthn API. The fallback branch (bridge unreachable) synthesises a local pseudo-passkey — no real cryptographic credential is created in that path.

**`src/store/settings/useAccountPasskeysStore.ts`** — the Zustand store handles all three bridge round-trips:

- `registerOptions` (`lines 65-72`): `POST /api/account/passkeys/register/options` — fetches the challenge and RP parameters from the bridge.
- `verifyRegistration` (`lines 74-93`): forwards only `credentialId`, `publicKey` (from `response.attestationObject`), and `transports` to `POST /api/account/passkeys/register/verify`; the private key is never present in this payload.
- `remove` (`lines 98-107`): `DELETE /api/account/passkeys/:passkeyId` via the bridge.

The bridge endpoints are prefixed `/api/account/passkeys` and proxied through the osionos-bridge service (`VITE_API_URL`, default `https://localhost:4000`), which holds the BaaS service-role key and reaches grobase's PostgREST/Kong layer — the app never calls grobase directly.

## How we know it is applied

`@simplewebauthn/browser` is declared as a **production dependency** in `apps/osionos/app/package.json` (not `devDependencies`):

```json
"@simplewebauthn/browser": "^13.3.0"
```

The import is at the top level of `SettingsCenter.tsx` (line 17), not behind a lazy boundary, so it is included in the settings chunk for every authenticated user. The store (`useAccountPasskeysStore.ts`) is consumed directly from `SettingsCenter` via `useAccountPasskeysStore`, making the bridge calls live whenever the settings panel is mounted. The `activePasskeys` filter (`passkeys.filter(p => !p.removedAt)`) drives the rendered passkey list, confirming the hydrate/list path is also wired.

The quality gate `npm run test:quality` (graph-engine tsc → root tsc → eslint `--max-warnings=0` → `check-style-tokens.sh`) must pass clean before any merge; a broken import of `@simplewebauthn/browser` would fail the tsc pass, so the dependency wire is CI-enforced at every build.

## Reference

The [Multifactor Authentication Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html) details the authenticator categories and explains why hardware-bound credentials (FIDO2/WebAuthn) are categorised as the strongest possession factor. It specifically distinguishes phishing-resistant authenticators — those whose challenge-response is origin-scoped — from OTP-based schemes that can be intercepted in real time; osionos's use of `startRegistration` / `startAuthentication` from the SimpleWebAuthn library implements exactly the phishing-resistant model described there.

## Residual risk / assumptions

- **Fallback pseudo-passkey:** when the bridge is unreachable, `handleRegisterPasskey` synthesises a local record with a `local-` prefixed credential ID and no real attestation. This record is persisted to `zustand/persist` under the key `osionos:settings:account-passkeys` and to the bridge on the next available call (`verifyRegistration` falls back to `localPasskey()`). The local record provides no cryptographic authentication guarantee; it is a UX placeholder, not a security control.
- **Server-side verification not visible here:** the bridge's `/api/account/passkeys/register/verify` handler must perform full attestation verification (challenge match, RP ID, origin, counter). That logic lives in the osionos-bridge service (`vendor/born2root` / bridge-api), not in the client code reviewed here; its correctness is assumed but not verified in this document.
- **No assertion (login) flow in scope:** this document covers registration only. The authentication assertion path — `startAuthentication()` + `/api/account/passkeys/authenticate/verify` — is a distinct flow not yet surfaced in the settings UI; the passkey cannot currently serve as a login factor without that path being wired end-to-end.
- **Origin binding depends on TLS:** the RP ID is derived from the served origin. The local TLS CA (`make certs && make certs-trust-local`) must be trusted by the browser for `https://localhost` to resolve correctly; an HTTP origin or an untrusted cert would prevent the authenticator from completing the ceremony.
- **Supply chain hold:** `@simplewebauthn/browser` is subject to the 10 080-minute (`minimum-release-age`) pnpm supply-chain policy in `apps/osionos/app/.npmrc`; new patch releases are held for seven days before being eligible for installation.
