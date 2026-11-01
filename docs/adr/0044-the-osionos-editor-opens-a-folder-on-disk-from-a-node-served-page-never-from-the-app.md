# 0044. The osionos editor opens a folder on disk from a node-served page, never from the app

- Status: proposed (devil: BLOCK as proposed, PROCEED-WITH-CONDITIONS F1–F20 on the node-page variant, 2026-11-01; osionos `docs/ide/vscode-backend/devil-verdict-2026-11-01-editor-on-disk.md`)
- Date: 2026-11-01
- Deciders: the owner ("code based on the interface of osionos and monaco", picked "osionos editor on disk", no VS Code window); devil (ruling). The builder carries F1–F20
- Amends: [0041](0041-the-web-terminal-opens-in-place-on-a-node-served-frame-with-a-one-shot-machine-token.md), whose decision "The IDE (editor, explorer) keeps its window" no longer holds for folders on disk

## Context

- Since 2026-10-30 (C0-F2), app-origin code can reach no file and no shell on the user's machine. The app
  may only hand over a token, ask to show a file, or name a refusal (osionos
  `src/features/ide/vscode/ideFrameProtocol.ts:12-17`). The terminal frame accepts no write from the app
  (`src/features/ide/model/terminalAppLink.ts:46-65`).
- The in-app editor saves to the page store first, and its LSP sends the full text to the bridge sandbox
  (`src/features/ide/ui/CodeFileView.tsx:86-95,196-199`; `model/lspMonaco.ts:248`). Its conflict handling is
  keyed by page (`model/ideSyncConflicts.ts:14-25`).
- `FsOpTransport` has no `watch` and returns exec output (`src/features/ide/vfs/sandboxFsOps.ts:18-30`).
- The node's ws `maxPayload` is per server and applies before auth (`packages/osionos-node/pty-runtime.mjs:43`).
- `~/.osionos` holds the machine key and the node's own code (`ls -la ~/.osionos`).
- Measured 2026-11-01 on the owner's laptop: `fs.inotify.max_user_watches` = 65536, shared with the VS Code server.
- Unknown when this was written: Monaco's CSP needs on the node page; the cost of extracting the explorer
  (its rows import app stores); LNA for a second loopback frame.

## Decision

- osionos-node serves an editor page at `http://127.0.0.1:4100/editor/`: osionos's explorer and Monaco,
  with its own CSP (`connect-src 'self'`). The dock frames it as it frames `/terminal/`.
- That page is the only code that lists, reads or writes the disk. It uses `ws://127.0.0.1:4100/api/fs`,
  which has its own ws server and the shared credential module (the same token, jti guard and device
  records as `/api/pty`).
- The app sends the frame only credentials, colours and `open {root, path}`. It receives only state and the
  open file's basename and dirty flag. No file content, listing or path reaches the app, the page store, the
  bridge or its LSP.
- Roots are picked by a click in the frame and kept in `~/.osionos/roots.json`, bound to the framing app
  origin. `/`, `$HOME`, its ancestors and `~/.osionos` are never roots. Every path resolves by realpath
  under its root.
- A save carries the hash of what was loaded, so it never overwrites a change made on disk. A file that is
  not UTF-8 is not opened.

## Alternatives considered

- **The app's own explorer and editor drive a relay frame (the proposal)**: makes app-origin code a file
  principal on every paired computer. One XSS or one develop push to the beta could read every picked
  folder and write `.git/hooks`, which runs code at the next commit. Rejected:
  `.out-of-scope/app-driven-file-relay-to-the-users-machine.md`.
- **Reuse CodeFileView by importing disk files as pages**: uploads the user's files, `.env` included, to the
  workspace database and the sandbox LSP (`CodeFileView.tsx:89`, `lspMonaco.ts:248`). That breaks the
  own-machines sovereignty rule.
- **Reuse the terminal page as the relay**: same origin either way, so the split is no boundary. It would
  break W10's "accept only a token" and pull the terminal override into the editor's bundle.
- **The VS Code window that the node already serves**: refused by the owner ("no VS Code window").

## Consequences

- On the web, file access has the same principal as the terminal: node-served code, with the human at the
  keyboard. Root confinement guards against bugs and hostile symlinks. It is **not** a security boundary
  against whoever controls the frame, who already has a shell.
- Run, format, LSP and AI on disk files are not part of this decision: they went through the bridge
  sandbox. The dock's terminal is the run path.
- The beta frames this page under the owner's W15 and R5 decisions. Withdrawing W15 withdraws it.
- The builder owes F1–F20. The status becomes "accepted" when they are green and shown. F19 (Chrome e2e) is
  measured before merging to develop, because a merge ships to the beta.
- To reverse: drop `/editor/`, `/api/fs` and `roots.json`, in one release and a node restart. Files already
  written stay written.
