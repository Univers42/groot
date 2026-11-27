# DRAFT: grobase-link mode on the production host

- Status: draft, untracked. Ruled by devil 2026-11-23. Full ruling: `/mnt/storage/dlesieur/scratch/link-mode/RULING.md`.
- Scope: which link mode (`ssh` / `direct`) the production host runs, and how its containers stop depending on an accident.

## Context

- **Nobody chose ssh mode.**
  - Production ran direct mode until 2026-11-16 14:17, and ssh mode since 2026-11-18 22:18.
  - The cause is in the Makefiles. `utils/mk/datacenter.mk:7-14` points `GROBASE_LINK_CONF` at `.env.grobase-link.local` once vault42 credentials turn `DATACENTER_ON` on (`utils/mk/pipeline.mk:8,10`).
  - That file is absent, so `resolve_auto` (`scripts/lib/grobase-link-target.sh:128-143`) picks ssh.
- **The ssh master does not authenticate the VM.**
  - `open_master` (`scripts/grobase-link.sh:94-106`) uses the user's ssh config, which has `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` for loopback 4242.
  - That port is a qemu hostfwd. It is free whenever qemu is down, and that is when the link retries every 20 s.
  - An impostor there would feed `.env.local` its own secrets and see all Kong and Redis traffic.
- **ssh mode skips the WAF.**
  - Kong logged 693 `/rest/v1` requests from the link source and 2 from the WAF in 15 minutes.
  - The VM WAF's loopback `:8880` (nginx `listen 80`) proxies to Kong and applies CRS: a SQLi or XSS probe gets 403 there and 401 on Kong `:8000`. `/admin/v1` without credentials gets 401 there, not 403.
- **ssh mode adds relay 4000 to `mini-baas-realtime`, whose `/v1/publish` has no auth** in grobase source (`realtime-gateway/src/rest_api.rs:103-131`).
- **The Redis target is the session store** for both the bridge and the auth gateway. Direct mode uses an ephemeral stand-in that every heal restart removes.
- **`make datacenter-configure` does not restore the old direct mode.**
  - It writes a WAF target through a DHCP-snapshot LAN address. Probed without credentials, that path answers 403 for `/admin/v1`, `/meta/v1` and publish.
  - `make all` runs it before `link` (`utils/mk/pipeline.mk:20`).
- **Rendered vs running env:** link keys differ only on calendar-bridge, empty vs unset. calendar-bridge also carries non-link drift, including `OSIONOS_BRIDGE_EMAIL_HASH_SALT`.

## Decision

| Option | Verdict | Worst axis |
| --- | --- | --- |
| A. Ratify today's auto ssh mode | BLOCK | cost on failure 5 (credential and session capture) |
| B. Restore direct mode | BLOCK | blast radius 5 (every relay user; sessions lost; `/admin/v1` 403) |
| C. Per-service env pins as the remedy | BLOCK (the bridge pin stays as part of D) | blast radius 4 (relay routing is not env) |
| D. Explicit, host-key-pinned ssh mode, Kong through the VM WAF `:8880`, relay 4000 closed | PROCEED-WITH-CONDITIONS | blast radius 4 |

## Consequences

The conditions for D are acceptance criteria and apply in order:

| Condition | Acceptance criterion |
| --- | --- |
| LM-1 | Read-only baseline: Kong sources, WAF 403 count on `:8880`, users of relay 4000, `lm-envdiff.sh` output. |
| LM-2 | `open_master` uses the `open_admin_master` pin pattern (`-F /dev/null`, `StrictHostKeyChecking=yes`, `HostKeyAlias`, seeded known_hosts, `ForwardAgent=no`, `IdentityAgent=none`). A bats test with an impostor sshd shows a non-zero exit and no env file written. |
| LM-3 | An explicit ssh `.env.grobase-link.local`, never `auto`. A required-mode guard in `grobase-link.service` dies on a mismatch. |
| LM-4 | The relay's 8000 route targets VM `127.0.0.1:8880`. Through the relay a SQLi probe gets 403 and `/admin/v1` gets 401. Kong sees the WAF as the source. |
| LM-5 | One-step rollback written, cutover on an explicit go, WAF 403 count within baseline for 1 h. |
| LM-6 | Relay 4000 dropped, or its users moved to WAF publish with a key, or publish auth proven in the VM image. |
| LM-7 | `datacenter-configure`, and therefore `make all`, cannot overwrite an existing link conf of another mode. Proven by a bats test. |
| LM-8 | The Redis target does not move. The dbsize count does not drop across the cutover. |
| LM-9 | `lm-envdiff.sh` shows 0 link-key diffs before every deploy-tree recreate. |
| LM-10 | Bridge pins are removed only after LM-2 to LM-4 have held for 7 days. |
| LM-11 | VM-restart drill (needs a go): the link refuses during the outage and recovers on its own. |
| LM-12 | No calendar-bridge recreate until the email-hash salt drift is ruled on separately. |
| LM-13 | The ai-dev containers on the production `mini-baas` network are recorded as a finding. |

Rollback after the cutover is to restore the previous conf and run `make link`. Sessions survive because Redis is unchanged.

## Still unknown

- U1: publish auth in the VM realtime image.
- U2: users of relay 4000 through code defaults.
- U3: CRS false-positive rate on bridge write bodies.
- U6: how calendar-bridge reads an empty link key versus an unset one.
- U8: whether the link is the only docker-gateway source in Kong logs.
