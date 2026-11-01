# 0034. The IDE runs on VS Code's server behind a non-public node proxy, and the browser never holds the server's token

- Status: proposed (devil verdict 2026-10-30: PROCEED-WITH-CONDITIONS for milestone 1, owner only; stage 1 and the desktop edition BLOCKED)
- Date: 2026-10-30
- Deciders: devil (ruled); the owner, sole user for milestone 1, lives with it on the laptop, the VM and later Windows/macOS

## Context

- The design is [ADR-006](../ide/ADR-006-vscode-backend-osionos-host.md):
  - `@codingame/monaco-vscode-api` 37.6.1 in editor mode;
  - code-server v4.138.0's bare server on each machine;
  - a bridge `/api/node/:id` same-origin proxy.
  It supersedes [ADR-004](../ide/ADR-004-page-files.md) decision 8 and moots ADR-005 S4U3 and S4U5.
- The spike passed 7/7 checks on the laptop and on the VM over `ssh -L`. The machine switch took 0.63–1.32 s on the dev server, and the build was 4.06 MB gzip (osionos `docs/ide/vscode-backend/spike-2026-10-30.md`).
- The server's root path sets its connection token as a 7-day `SameSite=Lax` cookie. It answers `/version` and `/delay-shutdown` without a token, and `/vscode-remote-resource?path=` serves any readable file (`lib/vscode/out/server-main.js`, code-server 4.138.0, minified).
- The spike put the connection token in the page URL and hard-coded workspace trust (`vscode-spike/src/main.ts:65,67`).
- The IDE edge passes a request with no `Origin` (osionos `scripts/ide-http-edge.mjs:27`). The app frames embeds with `allow-same-origin` (`src/widgets/embed-app/ui/EmbedFrame.tsx:39`).
- ADR-005 blocked the local PTY because page script reaches host APIs (`docs/ide/ADR-005-desktop-host-providers.md:56-60,162`).
- The deletion ledger's Phase-2 rows are imported by kept and later-phase modules (osionos `scripts/ide-preview.mjs:19`, `ide-server.mjs:22`, `bridge-ide-token.mjs:18,20`).
- Slim artifact sha256 is `6e576746bdc708ecff467fbc154ef6c45e81f0946e36025a748e6f78a6d78df4`; upstream asset sha256 is `5d63f26c5dabc2acd29610b9b27f413b016aa67019e2cfcdf54031625e18f535` (`sha256sum`).
- Unknown when this was written:
  - whether the client can be rooted under `/api/node/<id>/` (the spike routed at `/`);
  - the server's refusal of a mismatched commit;
  - the desktop `app://` origin's WebSocket path;
  - the upstream hash against GitHub's digest.

## Decision

- The IDE uses VS Code's server on every connected machine, with osionos drawing every panel.
- The server is pinned exactly:
  - the client pin equals the server's VS Code version, and its commit override equals the server's commit;
  - a skew fails the build.
- The slim artifact is built by a committed, deterministic script and hash-verified on the target before unpack.
- The server binds `127.0.0.1` with a token file at mode 0600. The browser never holds that token: the bridge injects it on the loopback hop.
- The browser reaches a machine only through `/api/node/:id`, on the non-public IDE origin. Its credential is an `HttpOnly`, `SameSite=Strict`, `__Host-` node capability. That capability is:
  - minted from `osionos_ide1`, with a sudo grant;
  - bound to `sub`, node and `exp ≤ 900 s`.
- The proxy forwards an allowlist of server paths. It sandboxes every response it does not need to execute.
- `ssh+` runs the system `ssh` with fixed argv and a validated alias. `tunnel+` is an owner-only opt-in kind with its own consent text.
- The browser worker extension host stays off. Each page holds one machine.

## Alternatives considered

- **ADR-006 as written (the app's origin, the token in the browser):**
  - A hostile `x.html` in any cloned repository, served by `vscode-remote-resource` on the app origin, runs script there. That reaches every machine's terminal.
  - The server's own root path would hand the browser a 7-day cookie holding its token.
- **Keep the hand-built IDE:** 4 LSP features, Python-only debugging, no git branches, and about 3 sandboxes (ADR 0022). It cannot meet the owner's request.
- **`--without-connection-token` behind the proxy:** any local process or user on the VM reaches a full-rights server on loopback.
- **Microsoft's VS Code server:** its licence forbids this use. Code-OSS REH built by us remains the exit, and decision 3 already uses it for Windows.

## Consequences

- The builder meets conditions C0–C23 of osionos `docs/ide/vscode-backend/devil-verdict-2026-10-30.md` as acceptance criteria. The load-bearing ones:
  - C5: the token is absent from the HAR, storage and logs.
  - C6 and C7: the capability, and the proxy's refusal list, each with one test.
  - C8: the node proxy is never on the Funnel bridge.
  - C9: the ADR-005 page-script hardening comes before `/api/node` opens.
  - C11: real workspace trust.
  - C14–C16: extract before deleting, and keep the relay seam, the BYO container path, the preview's opaque origin and the invariant tests.
  - C18: `ssh+` argv.
  - C20: the `tunnel+` consent text and action set.
- ADR-006 is amended before Phase 1 code (C0): decision 6 moves to the non-public IDE origin, a topology table is added, and two new falsifiers are added. ADR 0022 and `byo-agent/contract.md` D4 and §7.4 get amendment lines.
- A breach of the proxy or the capability is a host compromise of every connected machine, including the VM that holds grobase prod keys. That is accepted only while the only user is the owner and operator.
- Stage 1 (anyone else's machine or session) stays BLOCKED until D3 extensible (owner-signed OPEN), isolation, and a new ruling.
- The desktop edition gets no `/api/node` until a measured run (C23).
- Reverse this when the lockstep pin cannot follow a VS Code security release within the window the owner sets: move the server to our own Code-OSS REH build.

## Amendment 2026-10-30: socket mode replaces the token file (devil: ACCEPT-WITH-CONDITIONS)

- **Fact:** the server checks its token in the first framed `auth` message (`type===2&&!validate(v.auth)`, "Unauthorized client refused: auth mismatch", `server-main.js`). Injecting the token on the loopback hop would need a protocol-rewriting proxy.
- **Decision:**
  - The server runs `--socket-path <0700 dir>/reh.sock --without-connection-token`, with no `--host` or `--port`.
  - `ssh+` forwards socket to socket.
  - No TCP port opens on any side, and nothing ever bridges the socket to TCP.
  - The server's main pid opens no listening TCP port. `/version` and `/delay-shutdown` are no longer reachable from web pages in the owner's browser through loopback.
- **Replaces** the token-file and loopback-TCP part of C4 and the Decision above with A1–A7. C5 is restated as A8, and decision 7's text is fixed under A9 (verdict file, "Amendment ruling").
- **Added from the C0 check:**
  - C0-F1: the node cookie must work in the framed IDE page with real hostnames; otherwise use a top-level window, never `SameSite=None`.
  - C0-F2: the app↔IDE postMessage API checks exact origins, runs no code, and writes only `.omd` under the pages mount. With F2 green, C9 binds the IDE origin's document only.
- **New failure mode, accepted:** widened modes or a TCP bridge turn this into unauthenticated owner-level code execution. A1, A4 and A6 are the guard. Windows named pipes and macOS each get their own run.
