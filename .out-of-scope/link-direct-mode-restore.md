# Restoring direct link mode on the production host is out of scope

- Decided: 2026-11-23 · by devil (link-mode ruling, `scratch/link-mode/RULING.md` option B)
- Holds while: direct mode serves Redis from the ephemeral `grobase-link-redis` stand-in, and the WAF refuses `/admin/v1` to the host's direct path

## The concept

Write `.env.grobase-link.local`, either through `make datacenter-configure` or by hand with the tailnet target used until 2026-11-16, and restart the link so production goes back to direct mode.

## Why not

- **Sessions.** Redis holds bridge `session:` / `sudo:` / `mfa-fail:` keys and the auth gateway's lockout and OTP state. Direct mode swaps it for `grobase-link-redis` (`--save "" --appendonly no`), which `link-down` removes on every heal restart. The switch, and every later heal, logs everyone out and resets the lockout counters.
- **`datacenter-configure` writes a different mode than the one that ran.** It targets the WAF through `ip -4 route get` (a DHCP snapshot, already changed once on 2026-11-06). Without credentials that path answered 403 for `/admin/v1`, `/meta/v1` and `/realtime/v1/publish`, which breaks the registry URL of the bridge, osionos-ai, auth-gateway and calendar-bridge.
- **The hand-written tailnet variant depends on the NIC and the ISP.** An I225-V wedge takes down every Kong and Redis request on a host whose VM is local.

## Prior requests

- 2026-11-23 (link-mode ruling, option B).

## Reopen when

Direct mode serves a persistent Redis (or sessions stop living in Redis), and the host's direct path is proven to reach `/admin/v1` and publish without depending on the LAN address or the tailnet hairpin.
