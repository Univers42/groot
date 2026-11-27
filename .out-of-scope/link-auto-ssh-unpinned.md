# Ratifying the production host's auto-resolved, unpinned ssh link is out of scope

- Decided: 2026-11-23 · by devil (link-mode ruling, `scratch/link-mode/RULING.md` option A)
- Holds while: `open_master` (`scripts/grobase-link.sh:94-106`) takes host-key policy from the user's ssh config, the relay targets VM Kong `:8000`, and the relay serves 4000 to `mini-baas-realtime`

## The concept

Keep the ssh mode production fell into on 2026-11-18. Make it "deliberate" with a conf line, env pins, or a rendered-vs-running check, and change nothing else.

## Why not

- The master does not check the VM's host key. `ssh -G` gives `stricthostkeychecking false` and `userknownhostsfile /dev/null` for loopback 4242, a qemu hostfwd that is free while the VM is down, which is when the link retries every 20 s.
- An impostor there writes its own secrets into `.env.local` through `fetch_remote_env`, and sees every Kong and Redis exchange.
- The relay skips CRS. 693 of 695 `/rest/v1` requests in 15 minutes reached Kong without the WAF. The publish-socket ruling Answer 4 BLOCKED exactly that.
- Relay 4000 exposes an unauthenticated `/v1/publish` (grobase `realtime-gateway/src/rest_api.rs:103-131`) to all 10 containers on the host's `mini-baas` network.

## Prior requests

- 2026-11-23 (link-mode ruling, option A).

## Reopen when

The link master pins the host key (the `open_admin_master` pattern, proven by an impostor-sshd test), the 8000 route goes through the VM WAF `:8880`, and relay 4000 is gone or authenticated. That is option D, ruled PROCEED-WITH-CONDITIONS LM-1 to LM-13.
