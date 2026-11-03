# 0042. The osionos Connector pairs in one click, ships Linux-first to testers, and trusts production only

- Status: accepted with conditions (devil: PROCEED-WITH-CONDITIONS, 2026-11-01; osionos `docs/ide/vscode-backend/devil-verdict-2026-11-01-osionos-connector.md`). C-1 to C-24 are open
- Date: 2026-11-01
- Deciders: owner ("people should be automatically connected to their local machine without extra steps"), devil (ruling); the builder carries C-1 to C-24
- Builds on: [0037](0037-every-user-pairs-their-own-machine-and-the-bridge-signs-machine-tokens-with-ed25519.md), [0041](0041-the-web-terminal-opens-in-place-on-a-node-served-frame-with-a-one-shot-machine-token.md)

## Context

- The plan is osionos `docs/ide/vscode-backend/plan-2026-11-01-osionos-connector.md` (feat/osionos-connector, on develop d07545d9).
- develop has no Host check on the node. W1 exists only uncommitted in the web-terminal worktree (`git grep isNodeHost d07545d9 -- packages` is empty).
- The beta is public through Funnel (groot bb25044e), runs every develop push, and is trusted by the owner's node (W15).
- Today the machine side confirms the approving account by email before saving (osionos `packages/osionos-node/pair.mjs:57-62`). Step 4 of the plan drops that confirmation.
- Unauthenticated pairing starts are capped at 20 per 600 s globally. Codes live 300 s. Behind Funnel without an IP header, every caller shares one client key (osionos `scripts/bridge-machines-pairing.mjs:21-23,42,68-69`).
- The bridge does not record the node's version, so it cannot switch off old installs (`scripts/bridge-machines.mjs:134`, `packages/osionos-node/heartbeat.mjs:66`).
- No path revokes machines on "sign out everywhere" or on account erasure (`grep -rn revokeMachine scripts/`).
- Production and beta both send `frame-ancestors 'none'` and `X-Frame-Options: DENY` (measured with curl, 2026-11-01).
- Unknown when this was written: U1 (LNA / Safari), U2 (ConPTY), U3 (SEA), U5 (signing and key custody), U6 (pipeline), U7 (peer uid on macOS/Windows), U8 (port squatting on a multi-user computer), U9 (the sandboxed same-uid app).

## Decision

- The Connector is the terminal-only node: pairing and heartbeat, with the IDE as a component it downloads on demand.
- It pairs when the person clicks Allow in the app, behind the step-up. The code reaches the app only from the computer's own loopback frame.
- It trusts only the production app origin by default.
- On Linux it refuses loopback peers owned by another uid.
- After pairing it posts a native notification naming the account.
- The first release is a Linux x64 .deb for named testers, together with a bridge-side minimum-version floor.
- Self-update, macOS/Windows, and a public Download button each wait for their own conditions.

## Alternatives considered

- **Step 4 as written (the framing session's account)**: the Connector cannot observe that account. Loopback headers are forgeable by any local process, so in practice it means "whoever claims the code". That gives a shell to another OS user, and a sandbox escape to a same-uid snap or flatpak.
- **Keep the machine-side email confirmation as a terminal prompt**: the owner rejects it ("too complex for users"). Kept only for manual code entry (C-6).
- **An authenticated start (the app posts the machine-signed pubkey to the bridge with its session; no code)**: removes the global start cap and the code. It has the same local-binding problem, and it is a protocol change. A reasonable later step, not required.
- **A public Linux release before any update path**: every install becomes a one-way door. The version floor (C-13) is the cheap remote off-switch.
- **Ship the beta as a trusted origin**: every develop commit could pair any user's computer to any account. See `.out-of-scope/connector-trusts-non-production-app-origins.md`.

## Consequences

- C-1 to C-24 in the verdict are the acceptance criteria.
- Stage L is gated by C-1 to C-9, C-11 to C-13, C-17 to C-22, U1 (Chrome and Firefox) and U3.
- Stage M is blocked on C-14 to C-17, C-24, U2, U5, U6 and U7.
- Stage P is blocked on C-10, C-23, U8 and U9.
- Residuals until Stage P:
  - On a multi-user computer, another uid can squat port 4100 before the first pairing.
  - While the Connector is unpaired, a same-uid sandboxed app can pair it to its own account. C-4 bounds the window and C-9 detects it.
- Unsigned macOS/Windows installers never go public. See `.out-of-scope/unsigned-connector-installers-for-the-public.md`.
- To reverse:
  - Raise the bridge's version floor (C-13). Every installed Connector goes inert for new shells.
  - Then remove the package.
  - Machines stay listed until revoked (C-18, C-20).

## Owner override of C-3 (2026-11-01)

The owner overrode C-3: "beta is allowed too, otherwise we're stuck with configuration; we need to take
some shortcuts to advance faster." The shipped Connector trusts production
(`https://baas.tail10f2ea.ts.net:8443`), the beta (`https://baas-beta.tail10f2ea.ts.net`) and the
desktop app (`app://osionos`) out of the box. Accepted risk: anyone who can push to osionos
`develop` ships code that, once a person opens the beta, signs in and clicks Allow, can pair that
computer and open its shells. Every other condition stands. To withdraw it, drop the beta from the
Connector's built-in origin list in one release, plus the C-13 minimum version that turns off the older ones.
