# DRAFT: the connector stays paired until a bridge-signed removal, and the 12 h / 30 d trusted browser opens files only under the app origin that earned it

- Status: draft, untracked. Ruled by devil 2026-11-27: PROCEED-WITH-CONDITIONS, TB1–TB25.
  Per part: D1, D2, D3, D4, D6 and D7 are PROCEED-WITH-CONDITIONS, and D5 is PROCEED.
- Date: 2026-11-27.
- Design ruled: `docs/superpowers/specs/2026-11-27-connector-trusted-browser-design.md` (approach A).
- Code read: osionos `origin/main` d9bc375ca (`~/.osionos/src`, clean). All `file:line` references
  below are at that commit, except the groot `models/` and `docs/adr/` files.
- Prior rulings this sits on:
  - web terminal in place, Amendment 1 R1–R14 (ADR 0041), with the owner's R5 override at
    `0041:68-76`
  - editor on disk F1–F19 (ADR 0044)
  - the owner's C-3 override in ADR 0042 (`0042:53`)

## Context

### The design's strongest case

Approach A adds no new credential. The editor gets the remembered opening the terminal has had
since aebe75df, under the same rule:

- a device secret, plus
- a 60 s bridge-signed resume assertion, spent through the same jti guard.

F5 of the editor-on-disk ruling asked for exactly this: "the same `verifySession`, the same jti
guard, the same device records" (`devil-verdict-2026-11-01-editor-on-disk.md:157-162`).

The 12 h idle / 30 d absolute window is strictly tighter than the 30 d / 90 d the owner already
accepted (ADR 0041 R5 override). Making removal need a bridge signature closes P4, where a bare
410 from any bridge (a DB restore, a misrouted URL) erases the pairing. Approach B (a cookie the
connector mints itself) was rightly rejected: it would stop asking the bridge on each opening.

### What the code says, and what the design missed

**1. The editor shares its fs session secret across app origins (amplified by D1).**

- Every frame of the editor page answers `secret?` on `BroadcastChannel("osionos-editor")` with
  its session secret (`src/editor-client/session.ts:66-70`, `:29-44`).
- The answer is not tied to the asker's app origin.
- The wire's `appOrigin` falls back to the first configured origin while the parent has not
  spoken: `linked.appOrigin() ?? appOrigins()[0]` (`session.ts:87`).
- The socket opens at client creation, before any link (`src/features/ide/vfs/nodeFsClient.ts:98-118`).
  The origin is read at send time (`:103`).
- The node accepts a `secret` opening under any configured app origin. The session does not
  record the origin it was opened under (`fs-service.mjs:150`, `node-credentials.mjs:53`).
- Production and the beta are one storage partition (Amendment 1, A1: `ts.net` is on the Public
  Suffix List).

So, with production editor open in one tab, a beta-framed editor frame can:

- take production's secret over the channel
- open `/api/fs` with `appOrigin = production` (the fallback, before the beta speaks)
- list production-bound roots inside a beta page

None of this needs a beta step-up. That breaks the sentence the R5 override rests on: "R4 still
binds each secret to the origin that received it" (`0041:73-75`).

The gap exists today, but only after a step-up. D1 makes production editor sessions ambient on
every reload, so the precondition becomes "production is open in any tab".

What the beta gains is bounded. The app hears base names only, and adding a root takes a click in
the node's picker. Still, it is the R4 class the override relied on.

**2. D1's remember flag skips R6's consent for the editor.**

- The "Remember this computer" box renders only in the terminal's step-up
  (`src/features/ide/ui/NodeVsCodeTerminal.tsx:59`).
- The editor's step-ups render a bare `<SudoPrompt />` (`src/features/machines/ui/MachineFileTab.tsx:33`,
  `MachineExplorerSection.tsx:73`).
- The store defaults to `remember: true` (`src/features/machines/model/terminalFrameStore.ts:15`).

D1 as written would mint `remember: true` from an editor step-up that never showed the box. That
issues a device secret which also opens a shell. R6 requires "only when the user checked
'Remember this computer'".

**3. D2's closing touch would bring the remembered file back after removal (R8).**

- The 410 path deletes the file with a bare `rmSync` (`packages/osionos-node/heartbeat.mjs:76-80`).
  The in-memory map survives.
- `onGone` then calls `stop()` (`cli.mjs:196-201`). That runs `origin.close()`, then
  `pty.killAll()` / `disk.killAll()` (`ide-origin.mjs:224-230`), then `gate.leave` per socket.
- Under D2, `gate.leave` would run `touch` and then `save()`.
- `save()` writes every record still in the map (`remembered-computers.mjs:56-58`), so the file
  comes back.
- `revoke()` is safe only because it runs `devices.clear()` before `killAll`
  (`ide-origin.mjs:215-223`).
- The R8 test checks the file only after `beat.once()`, never after `stop()`
  (`tests/bridge/osionos-node-pty-remembered.test.mjs:127`).

**4. Two claims about "lock" and "10 s" are false.**

*Deleting the file while the node runs locks nothing.* D2 says deleting
`~/.osionos/remembered-computers.json` "ends every unlock". The store reads the file once, at
construction (`remembered-computers.mjs:61-65`). After that the map in memory decides, and the
next `open` or `issue` rewrites the file.

*Sign-out-everywhere does not end open sessions.* The threat table says removal or
sign-out-everywhere "ends it within 10 s". That holds for new openings:

- the resume mint refuses a revoked row (`spendIdentityCheck`)
- the sign-out cut-off is polled every 10 s (`scripts/bridge-machines.mjs:220-226`)

Open shells and editors live until their sockets close. The node's `revoke()` has no production
caller: `grep -rn '\.revoke(' packages/osionos-node` finds only `ide-origin.mjs:215`, and the
`.revoke(` calls are in tests. A live editor session can also be handed to new same-origin
frames over the channel indefinitely.

**5. D3 facts.**

- The bridge answers 410 for an unknown row and for a revoked row before it checks the signature
  (`bridge-machines.mjs:98`). It answers 401 only for a live row with a bad signature (`:100`).
- Revocation is one-way: `revokeMachine` patches only live rows, and no path sets `revoked_at`
  back to null. So a gone for a revoked row is always true.
- `signed()` NUL-joins domain-tagged parts (`scripts/ide-agent-frames.mjs:197`).
- Heartbeats run every 30 s (`heartbeat.mjs:24`, `:92`). Their `ts` must be within ±60 s and
  strictly increasing (`acceptHeartbeatTs`, `bridge-machines-presence.mjs`).
- Next keys are accepted only when signed by a pinned key.

**6. "Exit 0 stops it" (K4) holds on Linux only until the next login. On macOS it never holds.**

- The systemd unit is `Restart=on-failure`, enabled on `default.target` (`install.sh:210`).
- The launchd plist is `KeepAlive <true/>` (`install.sh:231`), so it restarts on any exit.
- After an archive, the restarted `connect` loops on `pair` with no TTY (`cli.mjs:250-269`). That
  calls the bridge's `pair/start` every 5 minutes, forever.

It cannot be hijacked: the confirm needs a typed `y` on stdin (`cli.mjs:236`, `pair.mjs:62`).
Under systemd and launchd, stdin is not a terminal. Still, a removed machine that keeps asking to
pair is a defect.

**7. Account erasure deletes the row; it does not revoke it.**

The row has `ON DELETE CASCADE` (groot `models/osionos-machines-migration.sql:69`), and the erasure
registry deletes it (`models/osionos-account-erasure-migration.sql:373`).

Under D3 that is an unknown row with an unsigned 410, which the connector now ignores. Today, a
deleted account's connector forgets itself. After D3 it keeps heartbeating, keeps
`machine.json`, and keeps open sockets until they close. It cannot mint anything new.

**8. `roots.json` is not forgotten on the 410 (F9, broken today).**

F9 says the file "is deleted on the heartbeat's 410 before `stop()`, on unpair, on re-pair and on
revoke" (`editor-on-disk.md:189-194`). The `fs-roots.mjs:13-17` header says the same.

But the heartbeat's forget list is only `[rememberedFile(env)]` (`cli.mjs:199`). The only caller
of `roots.forget()` is `revoke()` (`ide-origin.mjs:222`).

**9. D6: a corrupt `machine.json` already prints part of the key.**

`loadMachine` lets `JSON.parse` throw (`machine-identity.mjs:42`), and the CLI prints
`error.message` (`cli.mjs:275`).

Measured on Node v26.13.0 (2026-11-27, `node -e` with an 86-char canary value), V8's message
echoes up to 10 characters of the value at the error position:
`Unexpected token 'Q', ..."ivateKey":QQQQQQQQQQ"... is not valid JSON`.

Separately, the store's constructor rewrites or deletes the file when it drops records at load
(`remembered-computers.mjs:65`). A `status` that reuses it is not read-only.

**10. D4 facts.**

- `connectCommand` passes only the origin it runs on (`src/features/machines/model/machineChoice.ts:99-102`).
  That is P3.
- The CLI takes both flags repeated (`cli.mjs:95`) and requires remember ⊆ app (`cli.mjs:83-90`).
- Re-running the install line on a paired machine skips pairing (`install.sh:180`) and rewrites
  `start.sh` (`:189`).

### Remote attacker

No new remote path is found.

- The node answers on loopback only.
- Every opening needs a bridge-signed proof for this owner and machine.
- Pairing needs a local typed `y`.

This holds only with TB3, TB4, TB12, TB14 and TB16 in place: the cross-origin hand-off and the
gone message are the two new surfaces. The accepted residual is unchanged: any commit pushed to
osionos develop reaches the beta, and through it a shell (W15, the R5 override, the C-3 override).

### Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | Shell and files on every paired machine, testers included (C-3 override) |
| Reversibility | 3 | The code reverts, but shipped connectors change only when people re-run the install line |
| Cost on failure | **5** | A wrong opening is a shell on someone's laptop |
| Confidence | 3 | Facts read or measured. Open: the link-vs-socket race in the wild, and the live bridge rollout |

Worst: cost on failure.

## Decision

Approach A proceeds with these conditions. They are acceptance criteria.

### D1: the editor takes the remembered opening. PROCEED-WITH-CONDITIONS

Shipping D1 without TB3, TB4 and TB5 is BLOCKED.

- **TB1.** One shared store and one jti guard.
  - One `devices` store and one `verifyResume` instance (one jti guard) go to both services
    (`cli.mjs:191`, `ide-origin.mjs:106-108`). `remembers` covers fs.
  - TEST: a resume assertion spent on `/api/pty` is refused on `/api/fs`, and the reverse.
- **TB2.** `readFsAuth` accepts `{device, assertion, appOrigin}` with `appOrigin` required. The
  `fs-service.mjs:150` origin check stays. TEST on `/api/fs`, each giving 4401 and 0 roots:
  - the device alone
  - the assertion alone
  - a replayed assertion
  - another owner's assertion
  - another machine's assertion
  - a device issued under production and opened under the beta
- **TB3.** The gate records the app origin a session was opened under. A `secret` opening under
  any other app origin is refused with 4401.
  - TEST: production's session secret sent with the beta origin gives 4401.
- **TB4.** The editor never opens `/api/fs` before its link is pinned.
  - Remove the `appOrigins()[0]` fallback (`session.ts:87`) from the wire origin and from the
    device store key.
  - A channel answer carries the answerer's pinned origin, and an asker takes it only if the
    origin equals its own.
  - TEST: a frame whose parent has not spoken sends no opening. A beta-pinned frame takes nothing
    from a live production frame in the same partition.
- **TB5.** R6 consent for the editor.
  - Every editor step-up shows `RememberComputerChoice`, with copy that names files and terminal.
  - The editor mints `remember: true` only when that box was shown in that step-up and is checked.
  - TEST: a step-up without the box mints `remember: false`.
- **TB6.** Re-run the earlier tests on the remembered path, and update the docs.
  - Re-run F1's canary and postMessage tests with the editor opened by the remembered path: the
    app gets no path, listing or content.
  - Re-run R4's cross-origin test for the editor.
  - Update the headers that say fs never takes the remembered opening: `pty-service.mjs:13-22`,
    `node-credentials.mjs:20-25`, `session.ts:1-4`.
  - Update ADR 0041's R5 override text (30 d / 90 d → 12 h / 30 d; "shells" → "shells and files").
  - Update ADR 0044.

### D2: the unlock window is 12 h idle, 30 d absolute. PROCEED-WITH-CONDITIONS

The owner's numbers are safe: strictly tighter than what was accepted, and re-judging at load is
stricter still.

- **TB7.** `REMEMBER_LIMITS = {8, 12 h, 30 d}`.
  - The caveat at `remembered-computers.mjs:25-26` states the new numbers.
  - TEST at idle 12 h ± 1 ms and absolute 30 d ± 1 ms, both on `open` and at load.
- **TB8.** `touch(hash)` is narrow.
  - It acts only on a record still in the map that is still live.
  - It sets `lastUsedAt` only: never `createdAt`, never re-adds a record, never writes after
    `clear()`.
  - The session keeps the hash of the record it opened or issued.
  - TEST: `touch` after `forget`, after `clear` and after expiry is a no-op and leaves no file.
- **TB9.** Every removal empties the in-memory map: the heartbeat path calls `devices.clear()`,
  not a bare `rmSync`, before `stop()`.
  - TEST: a removal with a remembered shell and an open editor leaves no
    `remembered-computers.json` after `stop()` resolves.
- **TB10.** The guide's "lock now" is either "Forget this computer" in the app, or stop → delete
  → start. It is never "delete the file" while the node runs. The design's D2 bullet 3 is
  corrected. The commands are copied from a run.
- **TB11.** The threat table and guide say exactly this:
  - Removal refuses new openings at once, and closes open ones within one heartbeat (30 s, after D3).
  - Sign-out-everywhere refuses new openings within 10 s, and leaves open shells and editors
    running.
  - "If your browser was taken, remove the machine."
  - The crash-loses-the-touch caveat ships.

### D3: pairing ends only on a bridge-signed removal. PROCEED-WITH-CONDITIONS

Signing a gone for an unknown row is BLOCKED, and so is a 401 for a revoked row.

- **TB12.** For a revoked row with a bad signature, the bridge's answer is byte-identical to the
  unknown-row 410: same status, code, message and headers. Never 401 (condition 6).
  - TEST: deep-equal the two responses.
- **TB13.** Before signing for a revoked row, the bridge:
  - verifies the signature against the row's `pubkey`
  - applies the ±60 s window and the seen-ts guard
  - never writes presence

  It then signs `signed('osionos-machine-gone-v1', origin, machineId, String(ts))` with the current
  key. Unknown rows are never signed.
- **TB14.** The connector acts only when all of these hold:
  - `gone.machineId` is its own machine id
  - `gone.ts` strictly equals the `ts` of that same request (closure-local, a safe integer)
  - `Object.hasOwn(keys, kid)`
  - the signature verifies over `goneMessage`

  TEST matrix: only the first case acts.
  - valid
  - ts ± 1
  - another machine id
  - an unknown kid
  - kid `__proto__`
  - a heartbeat-domain or next-key signature over the same parts
  - unsigned
  - a garbage body
- **TB15.** A verified gone does four things, in order:
  1. renames `machine.json` to `machine.removed-<ISO>.json`, keeping 0600 in the 0700 directory
  2. `devices.clear()`
  3. `roots.forget()` (F9, missing today)
  4. `stop()`, exiting 0

  Any other 410 is logged at most once per hour and changes nothing. The 410 test in
  `osionos-node-pair.test.mjs` is rewritten: an unsigned 410 keeps `machine.json`.
- **TB16.** No unattended re-pair.
  - `connect` with no `machine.json` and a non-TTY stdin exits 0 with "not paired: run the install
    line". It makes zero bridge calls (TEST).
  - The plist uses `KeepAlive {SuccessfulExit: false}`.
- **TB17.** Rollout is bridge first. Before any connector that ignores unsigned 410s is released:
  - a live probe on production shows a signed gone for a revoked test row, and the identical
    unsigned 410 for a bad signature. Command and output are recorded.
  - The caveats ship: new connector on an old bridge, and a key rotated while the connector was
    offline.
- **TB18.** The account-erasure consequence (Context 7) ships as a caveat in `heartbeat.mjs` and
  as a guide step (local unpair).

### D4: production and beta are both app origins. PROCEED-WITH-CONDITIONS

- **TB19.** The line passes the exact strings `https://baas.tail10f2ea.ts.net:8443` and
  `https://baas-beta.tail10f2ea.ts.net` as both `--app-origin` and `--remember-origin`.
  `connectCommand` prints that same line on either origin. A test asserts the string, and the CLI
  accepts it.
- **TB20.** The guide states the accepted risk for every installer, testers included, citing the
  R5 and C-3 overrides:
  - Within the window, any commit pushed to osionos develop can run commands in your shell
    without a code.
  - To withdraw it, drop the beta from the line and re-run it.
- **TB21.** Repair is proven by a run on a paired machine:
  - the machine id is unchanged
  - `start.sh` lists both origins
  - the unit or plist is rewritten, so TB16's fix lands

### D5: PROCEED

Copy only. Copy the command from a run.

### D6: `osionos-node status`. PROCEED-WITH-CONDITIONS

- **TB22.** No exception text from any file ever reaches output. `loadMachine` itself rethrows a
  fixed "machine.json is unreadable", which also fixes `cli.mjs:275` today.
- **TB23.** `status` is truly read-only.
  - It never calls `createRememberedComputers` or any writer. It uses a pure reader.
  - It prints counts, origins and ages, never hashes.
  - It parses only the origin flags from `start.sh` and never echoes the file.
  - It masks the email with the bridge's mask function, imported rather than copied.
  - It makes no signing call.
  - It checks the port through `/api/machine/self`'s machine id, so it can tell its own node from
    something else on 4100.
- **TB24.** Canary test. Plant canaries in:
  - `machine.json`, both valid and corrupted at the key
  - remembered hashes
  - `start.sh`

  None of them appears in stdout or stderr.

### D7: the guide. PROCEED-WITH-CONDITIONS

- **TB25.** The guide covers:
  - **Order.** Remove the machine in the app first. Then unpair locally: stop, rename
    `machine.json`, delete the remembered and roots files, disable the unit.
  - **Never paste** `machine.json`, an archive or the remembered file.
  - **Archives are not a restore path**, because revocation is one-way.
  - **Explanations** of "the bridge does not know this machine" and of the compromise procedure.
  - **Commands and output** copied from a real run.

## Alternatives considered

- **Sign a gone for an unknown row.** This makes any bridge that lost the row, or the wrong
  bridge, erase every pairing (P4). It also signs for anyone who knows a machine id. Refused:
  `.out-of-scope/connector-gone-for-unknown-machine.md`.
- **Keep the editor's channel origin-blind and rely on the node's origin check alone.** The
  fallback lets the frame claim production, so the node's check passes. Refused:
  `.out-of-scope/editor-session-shared-across-app-origins.md`.
- **Answer 401 for a revoked row with a bad signature.** That is a probe that tells revoked from
  unknown (condition 6).
- **Exit non-zero after removal so the unit stops.** Under `Restart=on-failure` it restarts every
  5 s forever.
- **Approach B, a connector-minted cookie.** Already rejected in the design: removal would take up
  to 12 h to bite.

## Consequences

- TB1–TB25 are the builder's acceptance criteria.
  - D1 cannot land without TB3, TB4 and TB5 in the same change.
  - D3's connector half cannot ship before TB17's live probe.
- **The person gets** a file or terminal that reopens with no code for 12 h after last use and
  30 d after the step-up, and a pairing no bridge accident can erase.
- **It costs:**
  - A deleted account's connector no longer cleans itself up (TB18).
  - A key rotation the connector missed leaves a removed machine heartbeating, though it can open
    nothing new.
  - Sign-out-everywhere still does not close open sockets.
- **Openings:**
  - The heartbeat's 200 could carry the owner's sign-out cut-off, so the node's dead `revoke()`
    gets a production caller.
  - Erasure could revoke and keep the row long enough for one signed gone.
- **Reverse it when** the beta stops being trusted (withdraw W15/R5, re-run the line without it),
  or when approach C (a passkey per opening) replaces the window.
