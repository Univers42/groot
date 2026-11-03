# Answering OSC 52 clipboard reads in the desktop terminal is out of scope

- Decided: 2026-11-01 · by devil (ADR 0039, condition T7)
- Holds while: the desktop answers a page's clipboard-read with no per-request prompt (no permission handler in `apps/osionos-electron/main.js`)

## The concept

The desktop's terminal should behave like VS Code's terminal. VS Code's terminal answers `ESC ] 52 ; c ; ? BEL` with the clipboard, so a program running in the terminal can read what was copied. Typical cases are vim or tmux over ssh, and a remote tool asking for the local clipboard.

## Why not

The answer is written into the pty as input. It reaches whatever is reading at the other end, a remote host over `ssh` included, with no prompt and no gesture. A hostile file shown with `cat`, a compromised server or a package script then gets whatever the person last copied, often a password. That breaks the owner's rule that data stays on the machine.

- VS Code's terminal loads xterm's `ClipboardAddon` with `readText → clipboardService.readText` and answers `?` unconditionally. No setting gates it (osionos `build/terminal/assets/index-*.js`, `importAddon("clipboard")`; `addon-clipboard-*.js`, `_setOrReportClipboard`).
- The shell sets no `setPermissionRequestHandler` (`grep -n setPermissionRequestHandler apps/osionos-electron/*.js` → none). Paste needs `allow="clipboard-read"` on the cross-origin terminal frame, so the read works there.
- OSC 52 **write** stays (copying from vim or tmux over ssh). Ctrl+Shift+V paste stays, because it is a gesture by the person at the keyboard.

## Prior requests

- 2026-11-01 (owner, through the plan): "VS Code's terminal design and features", which brings this along without anyone asking for it by name.

## Reopen when

The desktop asks the person on each OSC 52 read: a prompt in the terminal or a permission handler that confirms per request, naming the terminal as the requester. Re-decide then, from scratch.
