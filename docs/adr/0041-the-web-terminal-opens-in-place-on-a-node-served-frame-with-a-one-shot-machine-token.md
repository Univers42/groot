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
  remember. An owner override of R5 must be recorded here. R1–R14 landed on osionos develop in aebe75df (2026-11-04), each with its test; R-U1 (the production access-token TTL) and R-U2 (Safari, Firefox) stay open before main.
- **R5 overridden by the owner, 2026-11-01: the beta is remembered too.** Asked whether the beta should also
  remember the computer, the owner chose "Beta too". The owner's unit and the Connector name both
  `https://baas.tail10f2ea.ts.net:8443` and `https://baas-beta.tail10f2ea.ts.net` as remember origins.
  Accepted risk, replacing the W15 sentence above: after one emailed code per computer, any commit pushed to
  osionos `develop` can run commands in the owner's shell with no further code, for up to 30 days sliding and
  90 days absolute, until "Forget this computer", unpair or sign-out-everywhere. R4 still binds each secret to
  the origin that received it, so the beta's secret does not open shells for production's frame, or the
  reverse. To withdraw it, drop the beta from the remember origins and restart the node. Its secrets then stop
  opening shells, and R7 deletes them.

## Measured 2026-11-04 (G3 of `docs/ops/production-golive-verdict-2026-11-04.md`)

Engine runs used osionos develop `5f6b8ee1` and `tests/e2e/bridge-stub/rememberComputer.spec.mjs`: a real node
on 127.0.0.1:4100 serving the built terminal page, and a stub bridge. They ran in one container, `g3-browsers`
(image `osionos-browser-tests:download`, volume `remember_browser_test_node_modules`), on Docker's default
network, so its own network namespace gave the node a private :4100 and the owner's live node was not touched.
Firefox and WebKit were installed only inside the container (`playwright install --with-deps firefox webkit`,
WebKit 26.4 = webkit-2272). **WebKit stands in for Safari. It is not Safari.** The base command was
`CI=1 PLAYWRIGHT_BRIDGE_STUB=1 PLAYWRIGHT_REUSE_EXISTING_SERVER=1 node node_modules/@playwright/test/cli.js test tests/e2e/bridge-stub/rememberComputer.spec.mjs --retries=0`,
with vite started by hand (`VITE_API_URL=https://bridge.invalid --mode test --port 3004`). Each row adds its flag.

| Item | Browser / engine | Result | Command / evidence |
|---|---|---|---|
| Baseline | Chromium 1217 | **pass**, 49.8 s | base command |
| Terminal in place | Firefox, headless | **opens**: all 6 opens connect, no hang, no W14 panel | `--browser=firefox` |
| Remember (R12) + R-U2 | Firefox, headless | **storage survives**: 3 reloads and 2 new tabs resume with no code; `token`=1, `resume`≥5, Forget (R8) works | `--browser=firefox --repeat-each=2`, with the 2 warnings below filtered in a throwaway spec copy: 2/2 pass, 4.0 min |
| Zero console | Firefox, headless | **FAIL**: 12 frame warnings, 2 per open: "Layout was forced before the page was fully loaded" (page) and "Failed to create WebGL context" (headless, no WebGL) | `--browser=firefox`, spec line 85. osionos #305 |
| Terminal in place | WebKit 26.4 | **opens**: all opens connect, no hang | `--browser=webkit` |
| Remember (R12) + R-U2 | WebKit 26.4 | **storage survives** (5/5 later loads resume), **but FAIL**: in 3/3 runs, 1 or 2 remembered loads also take the token path ~300 ms after a successful resume (`token` 2, 2, 3; expected 1). On production, that mint after 600 s asks for a code | `--browser=webkit` and `--repeat-each=2`, spec line 80. osionos #304 |
| U6, cadence | code read | With remember: one emailed code per computer per 30 days idle, capped at 90 days (`packages/osionos-node/remembered-computers.mjs:27`). Without remember: one code for each terminal open that comes more than 600 s after the last step-up (`scripts/bridge-account-sudo.mjs:51`), so a day with N such opens means N codes. The copy says only "opens here without a code for 30 days" (`src/features/machines/ui/RememberComputerChoice.tsx:23`). It says nothing of the 90-day cap or of the 10-minute window | `rg` on develop `5f6b8ee1` |
| R-U1, app session TTL | production bridge | `OSIONOS_APP_SESSION_TTL_SECONDS=2592000` (30 d) on `track-binocle-osionos-bridge-1`, the bridge behind baas:10000 | `ssh 100.94.109.44 docker inspect …`, names and values only |
| R-U1, what bounds the lag | code + production env | The resume mint verifies the bridge's own `osionos_v1` token (`scripts/bridge-account-sudo.mjs:73` → `verifyAppSessionToken`), not a GoTrue JWT. Sign-out-everywhere writes a per-user cut-off (`scripts/bridge-api.mjs:5303`), polled every 10 s; past 60 s stale, verification answers 503 (`scripts/bridge-session-tracker.mjs:37-38`). Cut-offs are on in production (`OSIONOS_SESSION_CUTOFFS` unset, service key and BaaS URL set). **The lag is ≤ 10 s, or the mint fails closed, not the 30-day TTL.** The caveat at `scripts/bridge-machines.mjs:222` ("statelessly … GOTRUE_JWT_EXP") is wrong and should be corrected | same `ssh`, set/unset only |
| R-U1, GoTrue access TTL | production VM | **not measured**: `ssh dc-lan` timed out. The repo value is `GOTRUE_JWT_EXP: 3600` (`apps/grobase/orchestrators/compose/base/auth-api.yml:42`). It does not bound the resume lag (row above) | — |

Not measured, and accepted for tonight: **real Safari** (macOS or iOS, ITP and storage partitioning on real
hardware), real (non-headless) Firefox with WebGL, the beta's own token `exp−iat` (no beta login was made), and
GoTrue's live `GOTRUE_JWT_EXP`. Waiver: the owner's standing instruction for the night of 2026-11-04 is
autonomy with no questions. The named risk is that Safari users can see the WebKit fallback (#304) as an emailed
code on a remembered computer, or a partition behaviour WebKit-in-Linux does not reproduce. Main stays gated on
#304. #305 is a console-bar defect, not a security defect.
