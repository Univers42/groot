# ADR-002 — Terminal: bridge-owned sessions on the existing byte-transparent transport

Status: PROPOSED (Phase 1) · Decides: RECON §6 obstacle 2 · Falsifiers at end.

## Problem

The transport layer is already right (rare, and worth protecting): xterm.js ↔ binary WS
frames ↔ `docker exec bash -l`, bytes unmodified in both directions, resize out-of-band,
server→client backpressure (RECON §1). What's missing is everything around it:

- **No lifecycle.** Nothing in the app provisions a sandbox (`/api/ide/session` has zero
  callers); a UI reload kills the shell (WS close → TTY close → SIGHUP); no reconnect, no
  replay; the reaper is max-lifetime (4 h) and guillotines terminals mid-use.
- **No flow control client→stdin**; no cwd binding to the VFS; no multi-terminal; auth
  token in the query string; no Origin check; failures are bare `socket.destroy()`.

## Options considered

**A — Per-connection exec (status quo), add reconnect by re-spawning.** Loses shell state
(history, cwd, running process) on every reload — precisely the brief's reconnect question
answered badly. Rejected.

**B — node-pty in the bridge.** A shell outside the sandbox violates the entire isolation
architecture. Rejected without ceremony.

**C — tmux/screen inside the sandbox.** Real reattach, but adds an in-sandbox supervisor
dependency, complicates the image, and hides the session model from the bridge (which must
still own auth/limits/reaping). Kept as a falsifier fallback, not the design.

**D — Bridge-owned session objects: the bridge holds the docker attach; client sockets
come and go.** Chosen.

## Decision

1. **`PtyProvider` boundary** (same shape as the VFS): `spawn(spec) → PtySession`,
   `attach`, `resize`, `dispose`, `capabilities()` (signals, resize, replay depth, cwd
   reporting). Today's only implementation is docker-exec-via-socket-proxy; ConPTY,
   osionos-native, and fly-machines arrive as providers, not rewrites.
2. **Sessions outlive clients.** The bridge creates the exec and OWNS the duplex. A
   `TermSession { id, user, workspace, execId, ring, clients }` keeps a **replay ring
   buffer** (256 KiB) of recent output. A client WS attaches → receives the ring, then live
   bytes; detach leaves the shell running. Reload = reattach to the same shell, history and
   running process intact. Session ids are server-derived (`user,workspace,termN`),
   enumerable via `GET /api/ide/session` (which finally gets callers).
3. **Provision from the product.** Opening the IDE shell (or the terminal) calls
   `POST /api/ide/session` to ensure the sandbox exists — the dead route becomes the
   entry point; the SCM/terminal panels stop saying "start it yourself" (RECON §4).
4. **Idle-aware reaping.** A session is *active* while a client is attached or output
   flowed within `IDLE_MS`. The container reaper consults the bridge's live session
   registry: reap = (no active sessions AND idle > idle-limit) OR age > hard-max. Bridge
   restart empties the registry → falls back to age-only (documented, acceptable).
5. **Flow control, both directions.** Server→client stays as-is (pause/resume on WS
   drain). Client→stdin gains a bounded queue (4 MiB): overflow closes the session with a
   distinct code rather than OOMing the bridge. Scrollback stays client-side (5000) +
   the server ring for replay; `yes` must be Ctrl-C-able, never a frontend OOM.
6. **CWD binds to the VFS.** The sandbox `bash` profile emits OSC 7 on prompt; the
   frontend parses it and exposes cwd as a `sandbox://` VPath — explorer reveal and
   "open terminal here" both speak VFS. Capability-flagged; fallback = exec
   `readlink /proc/<pid>/cwd` polling.
7. **Auth + failure taxonomy.** Token moves from the query string to
   `Sec-WebSocket-Protocol`; the upgrade handler enforces an Origin allowlist (same
   origins as REST CORS). Every failure closes with a WS code + reason
   (4001 auth, 4003 gate-off, 4004 no-sandbox, 4008 unsupported-lang, 4029 throttled,
   4013 payload-overflow) and the frontend prints the reason instead of a generic
   "[connection closed]".
8. **VT completeness is asserted, not assumed**: the Phase 5 corpus runs `vim`, `less`,
   `htop`, alternate screen, bracketed paste (500 lines), 24-bit color, OSC 8, wide
   CJK/emoji-ZWJ — reading the **serialized terminal buffer**, not the DOM. The resize APC
   escape gets strict full-frame validation so paste content can never trigger it.

## Consequences

- The bridge gains a session registry (memory-bounded: ring × sessions ≤ 6/user).
- `bridge-ide-exec.mjs` splits: transport glue vs session ownership — and finally gets
  unit tests with a fake docker duplex (the RECON §5 hole).
- Reaper semantics change from "4 h guillotine" to activity-based (hotfixed tactically
  already; this ADR is the durable home).

## What would falsify this decision

- If bridge-held attachments prove unstable across docker-ide restarts (exec loss), C
  (tmux-in-sandbox) returns as the session substrate under the same `PtyProvider` face.
- If the ring-buffer replay is insufficient for real workflows (users expect full
  scrollback after reload), sessions grow optional disk-backed scrollback in the sandbox
  volume — a policy change, not an interface change.
- If a future provider (fly Machines) cannot expose exec-level attach, the provider
  boundary must absorb it (WebSocket to a remote agent) — the consumer contract must not move.
