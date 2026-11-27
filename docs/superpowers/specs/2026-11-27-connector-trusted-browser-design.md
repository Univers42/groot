# The connector stays paired, and a trusted browser unlocks files and terminal for 12 hours

- Date: 2026-11-27
- Scope: osionos `packages/osionos-node`, `scripts/bridge-machines.mjs`, `src/features/machines`,
  the connector guide. References are to osionos `origin/main` d9bc375ca (= the copy installed in
  `~/.osionos/src`; `git diff d9bc375c origin/develop` is empty on these paths).
- Status: design, before the devil's ruling (`rules/risk.md`: auth, access control, secrets).

## Why

The owner (2026-11-27): the connector "disconnects too much and always asks for an email to
reconnect or pairing to the system completely"; pairing should happen "just once unless we
destroy it", with "a logout session of 12 hours or something like that"; a document opened from
"This computer" must survive closing and reopening its tab; the terminal too; nobody on the
internet may take control; and people need a guide that says how to pair and how to repair a
connector that is already installed.

## What is wrong today (evidence)

| # | Fact | Where |
|---|---|---|
| P1 | The editor (files) page has no remembered opening. Its socket takes a one-shot token or a session secret, and a session dies with its last socket. Every reopen or network drop needs a new token, and the bridge mints one only inside the 10-min step-up window, which means an emailed code. | `fs-wire.mjs:84-85`; `fs-service.mjs` gate built without `devices`/`verifyResume`; `node-credentials.mjs` `leave()`; `bridge-machines.mjs` `token()` → `requireSudo`; `SUDO_TTL_MS = 600_000` |
| P2 | The editor frame never asks for "remember", so no device secret is ever issued from the files tab. | `editorFrame.ts` calls `startMachineFrame` without `remember` (default `() => false`, `terminalFrameStore.ts`) |
| P3 | Only `--remember-origin` origins are remembered, and the owner's `start.sh` lists the beta only; production `:8443` is not even an `--app-origin`. | `~/.osionos/start.sh`; `cli.mjs` `rememberedFor` |
| P4 | Any HTTP 410 from whatever answers at the bridge URL deletes `machine.json`: unsigned, so a misrouted proxy, a wrong bridge or a database restore destroys the pairing. | `heartbeat.mjs` 410 branch (`rmSync`) |
| P5 | A shell dies when its socket closes (tab closed, laptop slept). | `pty-service.mjs` `end()` |
| P6 | With the service stopped, a paired person is shown the install pitch ("Connector isn't running" + download), not "start it". | `terminalFrame.ts` `PANELS` no-node |

Exposure, measured 2026-11-27 from a public Tailscale Funnel address: app `:8443` 200, beta
`:443` 200, bridge `:10000` 401 (`/api/machines`). The connector itself listens on
`127.0.0.1:4100` only and is not reachable from any other computer.

## Goals

- G1. Pairing is permanent: only a removal the bridge signs ends it, and even then the identity
  is archived, never deleted.
- G2. One confirmation unlocks this browser on this computer for both files and terminal; it
  stays unlocked until it has been unused for 12 hours (sliding), at most 30 days.
- G3. Closing and reopening a file tab or terminal tab, a dropped socket, a reload, a reboot of
  the browser: no email, no code, inside the unlock window.
- G4. Production and beta both work as app origins.
- G5. A guide: pair, check, repair, unpair; `osionos-node status` prints state, never a secret.

## Non-goals (this design)

- Shells that survive their tab closing (P5): reattach keeps a live shell waiting for anyone who
  can prove the session; it needs its own ruling. Phase 2.
- Passkey confirmation instead of password + emailed code. Phase 2: it changes the bridge's
  step-up, which the verify-password ruling (DRAFT VP1–VP22) governs.
- Taking the bridge's machine routes off Funnel (tailnet-only). Phase 2: needs proof that no
  public caller (Prismatica handoff, testers off the tailnet) uses `:10000`.
- Opening a machine from another computer (relay). Not asked; would make the connector
  remotely reachable, which is the anti-goal below.
- The VS Code page's own cookie (`ide-origin.mjs:119`, Max-Age = token exp ≤ 900 s).

## Anti-goals (a failure even if it works)

- The connector listening on anything but loopback, or accepting an opening without a fresh
  bridge-signed proof for this owner and machine.
- The app origin ever reading a device secret, a path, a listing or file content.
- A local command or doc that prints `privateKey`, a device secret or a token.
- Deleting `machine.json` on anything but a bridge-signed removal.

## Threat model, stated honestly

"100 % protected" is not a claim this design makes. What it keeps true:

| Attacker has | Can they open your shell or files? |
|---|---|
| Your password and your mailbox, on their computer | No: the connector answers only on your loopback; their browser's `127.0.0.1` is their own machine. |
| A stolen app session (cookie), on their computer | No, same reason. |
| A malicious website open in your browser | No: exact `Origin` on upgrade (`checkNodeOrigin`), CSP `frame-ancestors` = the app origins, Local Network Access prompt, no device secret readable cross-origin. |
| Script running in the app origin in your browser (XSS) | Can ask the bridge for a resume assertion and make the frame open, but cannot type into or read the frame (cross-origin, the app hears base names only). Unchanged by this design. |
| Your unlocked browser profile on your computer | Yes, inside the unlock window. This is the window the owner asked for; the bound is 12 h idle / 30 d. Removing the machine refuses new openings at once and closes open ones within one heartbeat (30 s, D3). Signing out everywhere refuses new openings within 10 s (resume mint refuses, R8) and leaves open shells and editors running. If your browser was taken, remove the machine (devil TB11). |

Routing: browser ↔ connector never leaves the machine (loopback); connector ↔ bridge is HTTPS
over the tailnet (WireGuard) with every heartbeat Ed25519-signed and every bridge key pinned.

## Approaches

- **A. Trusted browser, 12-hour unlock (picked).** Reuse the remembered-computer opening that
  already exists for the terminal (device secret in the connector page's storage + a 60 s
  bridge resume assertion, devil Amendment 1 R1–R14) for the editor too; change its windows to
  12 h idle / 30 d absolute; make removal require a bridge signature. Smallest change: one
  credential path, already ruled on, extended to the service devil F5 meant it for.
- **B. The connector mints its own 12-hour cookie.** Rejected: it stops asking the bridge on
  each open, so a removal or sign-out-everywhere would take up to 12 h to bite.
- **C. A passkey gesture on every open.** Rejected for now: strongest, but a gesture on every
  reopen and new WebAuthn verification server code; kept as phase 2 for the confirmation itself.

## Design (approach A)

### D1. The editor takes the remembered opening (P1, P2)

- `fs-wire.mjs` reads the same `{ device, assertion, appOrigin }` opening as `pty-wire.mjs`.
- `cli.mjs` builds ONE `devices` store and passes it, with `verifyResume`, to both the pty and
  the fs service (today only pty, `cli.mjs:~191`). One store, so the device secret a terminal
  got also opens files and the other way round; a record still binds owner, machine, app origin.
- A token open of `/api/fs` that carries `remember: true` issues the device secret, as pty does
  (R6). The connector's editor page stores it under the same storage key the terminal page uses
  (same node origin) — builder verifies the key name and reuses the terminal's storage code.
- `editorFrame.ts` passes `remember: () => useTerminalFrameStore.getState().remember` to
  `startMachineFrame`, so the existing "Remember this computer" box (default on) covers both.
- Update the headers that say "/api/fs never takes that opening" (`pty-service.mjs`,
  `node-credentials.mjs`).

### D2. The unlock window is 12 h idle, 30 d absolute (G2)

- `REMEMBER_LIMITS` becomes `{ maxRecords: 8, idleMs: 12 h, absoluteMs: 30 d }`. Records already
  on disk are re-judged at load with the new limits (stricter; the worst case is one step-up).
- Idle counts from the last *use*, not the last opening: a session opened with (or issuing) a
  device secret keeps that record's hash, and the close of its last socket touches
  `lastUsedAt` (new `devices.touch(hash)`). A 14-hour working session is not "idle".
  Caveat to ship: a connector crash loses the closing touch; idle then counts from the opening.
- No new "lock" command. "Forget this computer" in the app, or stop the connector → delete
  `~/.osionos/remembered-computers.json` → start it, ends every unlock. Deleting the file while
  the connector runs does not: it keeps the records in memory (devil TB10; the guide's commands
  are copied from a run).

### D3. Pairing ends only on a bridge-signed removal (G1, P4)

- Bridge `heartbeat()`: for a row that exists and is revoked, verify the heartbeat signature
  FIRST (only the machine itself can obtain its removal proof), then answer 410 with
  `{ gone: { machineId, ts, kid, sig } }`, `sig` = the bridge's machine-token Ed25519 key over a
  new `goneMessage({ origin, machineId, ts })` in `ide-machine-protocol.mjs`, where `ts` is the
  heartbeat's own `ts`. An unknown row keeps today's unsigned 410.
- Connector: a 410 acts only when `gone.machineId` and `gone.ts` equal what it sent and `sig`
  verifies against a pinned bridge key. Then it renames `machine.json` to
  `machine.removed-<ISO time>.json` (stays 0600), deletes the remembered-computers file, and
  stops (exit 0: `Restart=on-failure` does not loop). Any other 410 is logged once per hour as
  "the bridge does not know this machine" and changes nothing; heartbeats continue.
- Order: bridge first (the field is additive; old connectors keep acting on the bare 410), then
  connectors.
  Caveat to ship: a new connector talking to an OLD bridge ignores a removal; new openings are
  still refused (token and resume mints check `revoked_at`), but a shell already open lives on
  until its tab closes.

### D4. Production and beta are both app origins (G4, P3)

- The guide's install line passes `--app-origin` and `--remember-origin` for both
  `https://baas.tail10f2ea.ts.net:8443` and `https://baas-beta.tail10f2ea.ts.net` (the app's
  `REMEMBER_ORIGINS`, `machineChoice.ts`). `connectCommand()` in the app prints the same.
- Re-running that line on an installed, paired connector keeps the identity and rewrites
  `start.sh` (`install.sh:180-218`): that is the repair. Builder verifies `cli.mjs` accepts the
  flags repeated (two origins).

### D5. A paired person whose connector is stopped is told to start it (P6)

- The no-node panel adds, before the download: "Already set up on this computer? Start it:
  `systemctl --user start osionos-node`" (macOS: `launchctl load …`). Copy only.

### D6. `osionos-node status` (G5)

- Read-only. Prints: paired yes/no, machine id, account e-mail masked as the bridge masks it,
  bridge URL, app and remember origins (from `start.sh`), service active/enabled, loopback port
  answering, number of remembered browsers, and whether `machine.json`/`remembered-computers.json`
  are 0600. Never reads `privateKey` into output; prints names and states only. No network call
  that signs (a second signer would race the running connector's heartbeat `ts`).

### D7. The guide (G5)

`docs/ide/vscode-backend/connector-guide.md` in osionos (next to `osionos-node.md`): install and
pair; what the confirmation is and how long it lasts; check (`status`, `journalctl --user -u
osionos-node`); repair (re-run the same line); start/stop; unpair here (rename `machine.json`) and
remove in the app; what never to paste anywhere (`machine.json`). Commands copied from runs.

## Unknowns, resolved 2026-11-27

- K1. The device secret is `localStorage["osionos-remembered:<appOrigin>"]` on the node origin
  (`src/features/ide/model/terminalCredentials.ts` `rememberedStoreOver`). The editor page links
  through the same `linkTerminalToApp` but passes no store and throws on a device credential
  (`src/editor-client/session.ts` `credential()`); D1 gives it the same store and lets
  `nodeFsClient` send `{ device, assertion, appOrigin }` and keep/drop the device like the
  terminal page.
- K2. `--app-origin` and `--remember-origin` are `multiple: true` (`cli.mjs:95`); every remember
  origin must also be an app origin (`cli.mjs:87`).
- K3. A revoked row keeps `pubkey`: `revokeMachine` patches `revoked_at` and `is_default` only
  (`bridge-machines-store.mjs:92-95`), and `readMachine` selects `id,user_id,pubkey,revoked_at`.
- K4. `onGone` logs and calls `stop()` (`cli.mjs:200`); the builder makes the process exit 0 after
  an archive so `Restart=on-failure` does not restart it.

## Done when

- Unit tests: fs remembered opening (admit, wrong origin, replayed assertion, other owner);
  touch on last close; 12 h idle and 30 d absolute boundaries; signed 410 archives, unsigned and
  mismatched-ts 410 keep `machine.json`; bridge signs only after verifying the heartbeat.
- Live: on the owner's machine, open a file from "This computer", close the tab, reopen 20 min
  later: no step-up. Same for the terminal. Remove the machine in the app: the connector archives
  and stops within 30 s.
- osionos quality gate and the node tests green; the guide's commands pasted from a real run.
