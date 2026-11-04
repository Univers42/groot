# Letting the app's own code drive file operations on the user's computer is out of scope

- Decided: 2026-11-01 · by devil (ADR 0044)
- Holds while: the app's origin renders user content or third-party embeds, or is rebuilt from develop (the beta), and a paired computer trusts it

## The concept

To "code on the interface of osionos and monaco", the app's own explorer and Monaco editor open a folder on
the user's computer. A hidden node-served frame relays list/read/write/delete/watch ops that the app posts
to it, and the node runs them under the picked roots. The app holds no node credential.

## Why not

- It makes app-origin JavaScript a file principal. Since C0-F2 (2026-10-30), no app message can read a file,
  write one or type into a shell (osionos `src/features/ide/vscode/ideFrameProtocol.ts:12-17`). A relay that
  runs whatever the app posts is the credential, whoever holds the key.
- Writing inside a project root is code execution: `.git/hooks/*`, `.envrc`, `package.json` scripts, a
  `Makefile`, `.vscode/tasks.json`. Root confinement does not stop it, and a dot-segment ban stops only part
  of it.
- The beta is built from every develop push and shipped Connectors trust it (ADR 0042, C-3 overridden). So
  one XSS or one bad push becomes silent reads and writes on every tester's picked folders.
- The node-served editor page (ADR 0044) delivers the same feature with the terminal's principal and
  `connect-src 'self'`. The concept buys only UI reuse.

## Prior requests

- 2026-11-01 (owner via team-lead): the "osionos editor on disk" design, steps 2 and 3.

## Reopen when

The app that drives the relay is served from a dedicated origin that renders no user content or embeds and
is built only from a reviewed release branch, never develop. Or each write needs a human gesture checked by
node-served code. Either change is observable in the deploy config or in the frame's intake code.
