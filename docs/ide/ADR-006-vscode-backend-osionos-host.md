# ADR-006: VS Code's backend, osionos as the host

Status: PROPOSED (2026-10-30), amended under devil verdict C0 (osionos `docs/ide/vscode-backend/devil-verdict-2026-10-30.md`, ADR [0034](../adr/0034-the-ide-runs-on-vs-codes-server-behind-a-non-public-node-proxy.md)) · Decides: what runs the IDE behind the osionos workbench ·
Supersedes: [ADR-004](ADR-004-page-files.md) decision 8 ("standalone Monaco stays") ·
Moots: [ADR-005](ADR-005-desktop-host-providers.md) units S4U3 (fs IPC) and S4U5 (local PTY) ·
Amends: osionos `docs/ide/byo-agent/contract.md` D4 and §7.4 · Evidence: osionos
`docs/ide/vscode-backend/spike-2026-10-30.md` · Ledger: osionos `docs/ide/vscode-backend/REPLACED-BY.md`.
Falsifiers at the end.

## Problem

The owner wants osionos to replace VS Code for daily work. That means:
- open a folder on any of their machines (laptop, VM, later Windows and macOS);
- the machine's own shell, git with branches, a debugger, and language intelligence in any language;
- real VS Code extensions.

The IDE plane we built runs only in a hosted Docker sandbox, and that never scaled. ADR 0022 keeps it allowlist-only: about 3 boxes and no durable disk. Its parts are hand-built copies of what VS Code already does:
- an LSP relay with 4 features;
- a DAP that only speaks Python;
- a git allowlist with no branch UI;
- a file-sync agent.

ADR-004 decision 8 recorded the trigger to leave standalone Monaco: "when TextMate grammars or a web extension host become a requirement". This request is that trigger.

## Decision

1. **VS Code's services, osionos's UI.** The frontend adopts `@codingame/monaco-vscode-api` in *editor mode*: service overrides only, no VS Code views, workbench or title bar.
   - osionos draws every panel. Explorer, terminal, source control, run and debug, problems, search and extensions read VS Code's services (`IFileService`, `ITerminalService`, `ISCMService`, `IDebugService`, markers, extension management).
   - Options A (views mode) and B (Theia, OpenSumi, code-server's UI) of ADR-004 stay rejected: osionos stays the host.
2. **A VS Code server on every connected machine.** It is the remote extension host server ("REH") that VS Code Remote uses. Extensions, git, debuggers and language servers run there, against the machine's real files, shell and toolchains.
3. **Client and server move as one pin.** The server refuses a client whose commit differs (`remoteExtensionHostAgentServer.ts:351`).
   - Pin: `monaco-vscode-api` **37.6.1** (VS Code 1.138.0) with the bare server from **code-server v4.138.0** (MIT, commit `59c988c7`). The client presents that commit through `productConfiguration.commit`, the library's documented route for a same-version server.
   - A commit override across *different* VS Code versions is forbidden.
   - Windows has no code-server build, so it uses our own Code-OSS `vscode-reh-win32-x64` build, at the same version, when Windows machines arrive.
4. **A slim server artifact.** The node daemon installs the server without the Copilot (170 MB) and Mermaid (61 MB) built-ins: 153 MB tgz, 464 MB unpacked.
5. **One machine per page.** The library's configuration is set once per page. Each machine-workspace opens in its own tab or desktop window, and the workspace switcher lists them all. A switch measured 0.63–1.32 s.
6. **The IDE has its own non-public origin.**
   - The browser loads extension resources from the server (`/stable-<commit>/vscode-remote-resource`). That route serves any readable file with its real content type, and sends no CORS headers.
   - So the IDE client page and the `/api/node/<id>/` proxy both live on the **IDE origin** (`ide-server.mjs`, which holds no database credentials and is never on the Funnel bridge, C8).
   - The osionos workbench embeds that page as a frame. A hostile `x.html` in a cloned repository therefore runs, if at all, on the IDE origin under `CSP: sandbox`, never on the osionos app origin.
   - The client is rooted under the prefix through `serverBasePath`, and the server through `--server-base-path`.
7. **Machine kinds.** `local+<node>`, `ssh+<alias>` (the system `ssh`, the user's `~/.ssh/config`, a socket-to-socket `-L` forward; never TCP, A4) and `tunnel+<name>` (the machine dials out to the relay, reusing the BYO frames and pairing). There is no container kind.
8. **The browser worker extension host stays off** until it gets its iframe alternate domain. With it on and no domain, every `executeCommand` awaits activation on a host that never starts, and hangs (measured in the spike).

9. **No sandbox (owner's decision, 2026-10-30).**
   - osionos never runs someone's code on hardware it hosts. Code runs only on a machine its owner connected: local, ssh or tunnel.
   - The Docker sandbox plane is deleted in Phase 2, once its replacement is green. That covers `bridge-ide-sandbox.mjs`, `ide-docker.mjs`, the sandbox image, the socket proxy, the egress proxy and `osio-fs-agent.mjs`.
   - A user with no machine connected gets the page editor, not a terminal.
   - Milestone 2 (other people) means other people connecting **their own** machines, never a hosted box.

## Topology (milestone 1, owner only)

| Machine kind | Runs the VS Code server | Runs `ssh` / the relay link | Browser → IDE origin | IDE origin → server |
|---|---|---|---|---|
| `local+<node>` | osionos-node on the IDE origin's host, as the owner; the proxy runs **as the owner** in that same daemon and opens the socket directly (A6) | none | `__Host-` node cookie (HttpOnly, SameSite=Strict, ≤900 s, bound to sub+node), minted from `osionos_ide1` with a sudo grant | none: the Unix socket in a 0700 directory is the boundary (A1–A7) |
| `ssh+<alias>` | osionos-node installs and starts it on the target, as the target user | osionos-node, as the owner, holding the owner's `~/.ssh`; forward bound to loopback | same node cookie | none, through a socket-to-socket `ssh -L` forward (A5) |
| `tunnel+<name>` | osionos-node on the target, as the owner | the target's osionos-node dials out to the relay; the relay never chooses host or port (C20) | same node cookie | relay channel `reh`, owner-only opt-in |

**Not covered: the desktop edition** (`app://osionos`). Its main-process proxy cannot carry WebSockets, so it gets no `/api/node` until a measured run passes C5 and C7 (C23).

**Socket mode (ACCEPTED-WITH-CONDITIONS A1–A9, 2026-10-30; C4 is replaced by A1–A7).**
- C4 requires a 0600 token file, and the bridge injecting that token on the loopback hop.
- The server checks the token inside VS Code's framed protocol (the first `auth` message), not only on the HTTP upgrade. Injecting it means rewriting protocol bytes in the proxy.
- Proposed instead: the server listens with `--socket-path` on a Unix socket inside a 0700 directory created under `umask 077`, with `--without-connection-token`.
  - Only the owner's processes can open the socket, and those could read a 0600 token file anyway.
  - Other users cannot reach it, unlike a loopback TCP port.
  - `ssh+` forwards socket to socket (`ssh -L <0700 dir>/sock:<remote sock>`), so no TCP port opens on either side.
- Windows (named pipes) is out of milestone 1.

## Consequences

- The hand-built IDE pieces listed in `REPLACED-BY.md` are deleted phase by phase, each once its replacement is green. The `.omd` codec, the inbound page pipeline, the mount table's `pages` mount, tokens and the workbench layout stay osionos's.
- Any language with an Open VSX extension works the nvim way (install on demand). Microsoft-licensed extensions (Pylance, C# Dev Kit, cpptools) are replaced by open equivalents: basedpyright, OmniSharp, clangd and CodeLLDB.
- The desktop folder and local-terminal problem of ADR-005 disappears: the local machine runs the same server.
- Risk moves to running a server with full user rights on the owner's machines. Milestone 1 is owner-only. Milestone 2 (other people's machines) needs isolation and end-to-end tunnel encryption, each with its own ruling.

## Falsifiers
- The client cannot be rooted under `/api/node/<id>/` (`serverBasePath` plus `--server-base-path`).
- A commit-mismatched client hangs instead of being refused with a visible error within 10 s (C2).
- The `SameSite=Strict` node cookie is not sent inside the app's frame on the real hostnames (C0-F1); the IDE then opens as a top-level window, and the cookie is never relaxed.

- A same-version client is refused by the pinned server: decision 3 is wrong.
- A required panel (terminal, SCM, debug) cannot work without VS Code's views mode: decision 1 narrows to views for that panel only.
- Bundle growth exceeds 6 MB gzip, or a machine switch exceeds 2 s on the production build.
- The slim artifact breaks a built-in the IDE relies on (git, js-debug, TypeScript).
