# 0041. The web terminal opens in place, on a node-served frame, with a one-shot machine token

- Status: accepted with conditions (devil: PROCEED-WITH-CONDITIONS, 2026-11-01; osionos `docs/ide/vscode-backend/devil-verdict-2026-11-01-web-terminal-in-place.md`). W1–W16 are open
- Date: 2026-11-01
- Deciders: owner ("don't open other window … people will never accept to use the tools otherwise"), devil (ruling); the builder carries W1–W16
- Amends: [0034](0034-the-ide-runs-on-vs-codes-server-behind-a-non-public-node-proxy.md) C7g for `/api/pty` only; [0036](0036-the-desktop-app-opens-a-machine-as-a-child-window-and-a-loopback-node-cookie-drops-the-host-prefix.md) for the web terminal (the IDE keeps its window)

## Context

- C0-F1 (ADR 0034) forbids `SameSite=None`. A frame on 127.0.0.1 under the app's site is cross-site, so the cookie design needed a top-level window. A terminal needs no cookie: it needs a static page and one WebSocket per shell.
- osionos-node checks no `Host` header. `/api/machine/self` gates only on `sec-fetch-site`, which a DNS-rebound page satisfies (osionos `packages/osionos-node/ide-origin.mjs:129`, `machine-identity.mjs:129-131`, `scripts/ide-node-policy.mjs:90-95`).
- The machine token's claims are `{sub, machine, aud, iat, exp, jti}`. It does not record which app origin asked for it (`scripts/ide-machine-protocol.mjs:46-51`). Each mint needs a fresh identity check signed by the machine key (`scripts/bridge-machines.mjs:207-210`).
- Every node socket closes at its lease `exp` today (`node-proxy.mjs:101-149`).
- The owner's running node lists `https://baas-beta.tail10f2ea.ts.net` (develop, rebuilt on every push, ADR 0040) as an `--app-origin` (`~/.config/systemd/user/osionos-node.service`).
- The node has no WebSocket server and no dependencies. The pinned server ships `ws` 8.21.0 and `node-pty` 1.2.0-beta.15.
- Measured 2026-11-01: the server's `node-pty` loads and spawns under the node's Node 24.21.0. The ABI (`process.versions.modules`) is 137 on both Nodes.
- Step-up lasts 600 s (`scripts/bridge-account-sudo.mjs:51`).
- Unknown when this was written: Chrome LNA on a loopback iframe and its WebSocket (U1); `Sec-Fetch-Site` on a nested frame's own WebSocket (U5); Firefox and Safari behaviour; the step-up cadence UX (U6).

## Decision

- osionos-node serves VS Code's terminal panel page at `http://127.0.0.1:4100/terminal/`. It is static, with its own CSP (`connect-src 'self'`, `frame-ancestors <app origins>`).
- The web dock frames that page. For each shell, the frame opens `ws://127.0.0.1:4100/api/pty`. The upgrade needs an exact `Host` and an exact `Origin` (the node's own). Its first message is a bridge-signed machine token, consumed once through the same jti guard as `/api/node/session`.
- The wire is the desktop's pty port contract. At most 8 shells run per node, under `node-pty` from the pinned server.
- The token gates the opening, not the life. A shell dies when its socket closes, when the node stops, when the machine is unpaired, or on revoke.
- The IDE (editor, explorer) keeps its window.

## Alternatives considered

- **A `SameSite=None` node cookie in the frame**: forbidden by ADR 0034 C0-F1. Any site's requests would carry it.
- **Keep the top-level window (ADR 0036)**: the owner rejects it as unusable. It adds no security over the frame, because the window existed only to carry the cookie.
- **Close the shell at the token's `exp` (C7g as is)**: costs a step-up every 15 minutes and protects nothing on loopback. A shell open for one second can already install persistence.
- **Relay the pty through the app's origin to the bridge**: a remote path to a local shell, the exposure ADR 0037 avoided.

## Consequences

- On the web, the app never touches a pty socket; the node-served frame does. The frame is a real boundary here, unlike the desktop (ADR 0039, option (d)).
- `/api/pty` is a new loopback surface fed by any local process. W1–W5 make it a tested boundary, and W6 forbids a hand-rolled WebSocket parser.
- The heartbeat caveat "bounded by its tokens' 900 s life" stops being true for open shells. It changes with W8.
- Every `--app-origin` can now frame a shell. That is why trusting develop on the owner's laptop is the owner's explicit choice (W15).
- **W15, decided by the owner on 2026-11-01: the beta stays trusted.** "Beta and production are live apps that everyone can reach; that's important for my colleague." Accepted risk: every commit pushed to osionos `develop` can run commands in the owner's shell. That needs the owner to open the beta and pass the emailed step-up. To withdraw it, remove `--app-origin https://baas-beta.tail10f2ea.ts.net` from `~/.config/systemd/user/osionos-node.service` and restart the node.
- The builder owes W1–W16. The status becomes "accepted" when they are green and shown. U1 and U5 are measured before merging to develop (a merge ships to the beta). Firefox, Safari and U6 are measured before main.
- To reverse: drop `/terminal/` and `/api/pty`, and restore the window card. That is one release plus a node restart.

## Amendment 1 (2026-11-01): "remember this computer", PROCEED-WITH-CONDITIONS (R1–R14)

The owner: "we cannot ask constantly to people to send themselves a mail to be connected". The full
ruling is in the osionos verdict file, "Amendment 1".

- **Context.** `ts.net` is a public suffix (`/usr/share/publicsuffix/public_suffix_list.dat:15841`), so
  production and the beta are the **same site**, and the frame shares one localStorage partition under both.
  The node has no live revocation channel: `revoke()` has no caller, and only the heartbeat's 410 reaches it.
  The app-side whoami check is the app's word, so it is no boundary. A new bridge assertion in the machine
  token's format would be accepted by every node not yet updated.
- **Decision.** The node issues a device secret after a step-up, kept hashed on the node and in the frame's
  storage. It is a **second factor**: each later load also needs a bridge-signed resume assertion, minted with
  no step-up but after the machine-key identity check. The assertion has its own prefix, is 60 s and one-shot,
  and has `sub === owner`. The secret is bound to the app origin and issued to the production origin only.
  It lasts 30 days sliding, 90 days absolute, and at most 8 are kept per node. It is wiped on the 410, on
  unpair, on revoke and on "Forget this computer".
- **Alternatives.** A bearer device secret alone: 30 days with no step-up, readable under the beta and by a
  port squatter, and no revocation. A per-session ssh tunnel: a cloud-held key to every user's machine
  (`.out-of-scope/ssh-tunnel-per-terminal-session.md`).
- **Consequences.** One email per computer per 90 days. Sign-out-everywhere and machine removal take effect
  through the bridge refusing the resume mint, with a lag of up to the access token's TTL (unverified, R-U1).
  The W15 acceptance above ("needs … the emailed step-up") still holds only because R5 keeps the beta off
  remember. An owner override of R5 must be recorded here. R1–R14 are open.
- **R5 overridden by the owner, 2026-11-01: the beta is remembered too.** Asked whether the beta should also
  remember the computer, the owner chose "Beta too". The owner's unit and the Connector name both
  `https://baas.tail10f2ea.ts.net:8443` and `https://baas-beta.tail10f2ea.ts.net` as remember origins.
  Accepted risk, replacing the W15 sentence above: after one emailed code per computer, any commit pushed to
  osionos `develop` can run commands in the owner's shell with no further code, for up to 30 days sliding and
  90 days absolute, until "Forget this computer", unpair or sign-out-everywhere. R4 still binds each secret to
  the origin that received it, so the beta's secret does not open shells for production's frame, or the
  reverse. To withdraw it, drop the beta from the remember origins and restart the node. Its secrets then stop
  opening shells, and R7 deletes them.
