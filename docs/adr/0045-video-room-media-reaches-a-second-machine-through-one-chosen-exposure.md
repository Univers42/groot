# 0045. Video-room media reaches a second machine through one chosen exposure

- Status: proposed (draft for the devil; nothing below is opened until the ruling)
- Date: 2026-11-04
- Deciders: the owner (which exposure, if any); devil (ruling before any port or Funnel opens)
- Relates to: groot#174 (subject III.3), [0020](0020-mail-and-calendar-ship-public-as-static-previews-on-a-second-funnel-node.md) (a second Funnel node)

## Context

- Signalling is solved: browsers get `wss://<bridge origin>/livekit`, and local-https-proxy forwards only
  `/rtc` to the SFU (`infrastructure/tls/bridge-livekit.conf`, groot e7bd3e13). Production steps are on #174.
- Media is not. The SFU advertises the loopback and is published on it:
  - `infrastructure/livekit/livekit.yaml`: `use_external_ip: false`, `node_ip: "127.0.0.1"`,
    `tcp_port: 7881`, `port_range_start: 50000` / `port_range_end: 50060`.
  - On the production host (read 2026-11-04, `docker ps`, `ss -lunH`): `127.0.0.1:7880-7881->7880-7881/tcp`
    and `127.0.0.1:50000-50060->50000-50060/udp`.
  - A browser on another machine is handed ICE candidates of `127.0.0.1`. It cannot reach them, so the
    room stays at "connecting" after the `wss://` handshake succeeds.
- The host has no public address. Its interfaces are `enp7s0 192.168.1.132/24` (home LAN behind NAT)
  and `tailscale0 100.94.109.44/32` (`ip -4 -o addr show scope global`, 2026-11-04).
- The public entry is Tailscale Funnel, and it carries TCP only.
  - Today's main-node map is `FUNNEL_MAP="443:4322 8443:3001 10000:4000"` (`scripts/public-funnel.sh:44`),
    so all three ports it can serve are taken. The apps node holds `443:3102 8443:3103`
    (`scripts/lib/public-tailnet.sh`).
  - Funnel serves only 443, 8443 and 10000 and does not carry UDP: Tailscale's Funnel documentation.
    **Unverified here** — confirm against the installed `tailscale funnel --help` before any of this is built.
- LiveKit v1.11.0 offers both shapes below. Keys are from
  `https://raw.githubusercontent.com/livekit/livekit/v1.11.0/config-sample.yaml`:
  - `rtc.node_ip` with `use_external_ip: false`, a UDP `port_range`, and `tcp_port`. The sample says the
    TCP port "cannot be behind load balancer or TLS".
  - An embedded TURN server: `turn.enabled`, `tls_port`, `udp_port`, `domain`, `cert_file`/`key_file`, or
    `external_tls: true`. With `external_tls`, "LiveKit expects unencrypted traffic on tls_port, and still
    advertise[s] tls_port as a TURN/TLS candidate" behind an L4 TLS terminator.
- WebRTC media is DTLS-SRTP encrypted end to end to the SFU, whichever path carries it. Neither option
  adds plaintext HTTP (subject III.3 is about HTTPS for the backend; media is not HTTP).
- Unknown when this was written:
  - whether the Funnel can forward raw TLS-terminated TCP to a non-HTTP backend on this tailscaled version;
  - whether a third Funnel node gets the `funnel` capability under the tailnet ACL;
  - the bandwidth a relayed room costs the host's uplink;
  - whether the home router can forward a UDP range at all.

## Options

### A. A reachable `node_ip` with the UDP range (and 7881/tcp) open

What it exposes:
- The SFU's media ports on whatever address `node_ip` names, to anyone who can route to it.
- Each media port takes only DTLS-SRTP for a session that the signalling (behind TLS and the bridge's
  token) set up. But the ports are open to scanning and to UDP floods.

Two sub-variants:
- **A1, tailnet only.** Set `node_ip: "100.94.109.44"` and publish the ports on the tailnet address.
  - Only tailnet members get media: the team, the evaluators' machines if they join, and the beta.
  - The public Funnel visitors still get no media.
  - No new internet exposure.
- **A2, public.** The router forwards UDP 50000-50060 and TCP 7881 to `192.168.1.132`, and `node_ip` is
  the home's public IP.
  - This exposes the home IP to every participant: it appears in every ICE candidate.
  - It also opens 62 ports to the internet with no Funnel in front.

Exact config (A1):
```yaml
# infrastructure/livekit/livekit.yaml (production overlay copy)
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50060
  use_external_ip: false
  node_ip: "100.94.109.44"
```
```yaml
# deploy overlay, service livekit
ports: !override
  - "127.0.0.1:7880:7880"
  - "100.94.109.44:7881:7881"
  - "100.94.109.44:50000-50060:50000-50060/udp"
```

### B. TURN over TLS on 443, through a Funnel node of its own

What it exposes:
- One TLS port on a new public name, for example `osionos-turn.tail10f2ea.ts.net:443`, via a third Funnel
  node (the 0020 pattern).
- Behind it is LiveKit's TURN server. It relays only for clients holding the credentials LiveKit issues
  per session.
- No UDP and no home IP is exposed, because the Funnel relay's address is what clients see.
- Every remote room's media flows through the Funnel and the host's uplink: latency and bandwidth.

Exact config:
```yaml
# infrastructure/livekit/livekit.yaml (production overlay copy)
turn:
  enabled: true
  domain: osionos-turn.tail10f2ea.ts.net
  tls_port: 5349
  external_tls: true      # the Funnel terminates TLS; LiveKit reads plain TURN on 5349
  relay_range_start: 50100
  relay_range_end: 50160
```
```sh
# the third node's Funnel (as public-funnel.sh does for the apps node), TCP with TLS terminated by Funnel
tailscale --socket <turn-node-socket> funnel --bg --tls-terminated-tcp=443 tcp://127.0.0.1:5349
```
- `--tls-terminated-tcp` is **unverified** on the installed tailscaled; it is what external_tls needs.
- Publish only `127.0.0.1:5349:5349` on the livekit service. `rtc.node_ip` stays `127.0.0.1`: every
  remote client reaches media through TURN.

## Decision

None yet. Both options are written down for the devil to rule on.

The builder's suggested order is A1 first, because it adds no internet exposure and the subject's
defense runs on machines that can join the tailnet. B comes only if public visitors must get video.
A2 is listed for completeness and is not recommended: the home IP lands in every candidate.

## Consequences

- Until a ruling, #174's "a video room from a second machine connects" stays unshown. Signalling
  is `wss://` already.
- Either option is a deploy overlay plus a livekit.yaml copy. Neither changes the app or the bridge.
- A verify step must come with it: a second machine joins a room, and `chrome://webrtc-internals` shows
  a selected candidate pair that is not `127.0.0.1`: tailnet for A1, `relay` for B.
