# 0049. The link relay closes first on its TLS route

Status: accepted, 2026-11-06.

## Context

Host frontends reach the VM's Kong through the link relay: one `socat` per line of
`/link/routes`, the 8000 line an `OPENSSL:` address to the VM's `tailscale serve` on :443.
A probe through 127.0.0.1:28000 (every 0.3 s, 540 s) stalled 6/1500 times for 8 s+ with
0 bytes; direct curl over the same tailnet stalled 0/786.

A SYN/FIN/RST capture on tailscale0 (1820 connections) found 10 slow handshakes. 8 reused a
source port 12–59 s after that port's previous connection, which the VM had closed first; the
SYN-ACK came only once 60 s had passed since that close. The other 2 began before the capture.
The VM's serve listener is tailscaled's gVisor netstack behind a forwarder with no listening
endpoint, so a SYN matching one of its TIME_WAIT endpoints is dropped instead of reusing it.
Our kernel had no TIME_WAIT for the port, so it handed the port out again.

## Decision

`direct_routes` appends `,shut-down` to the 8000 route. On the client's EOF the relay sends the
first FIN, so the TIME_WAIT is ours and the kernel does not reuse the port for 60 s. On a
throwaway relay against the real VM (5 requests per variant, docker0 capture) the default left
the VM closing first 6/6; `shut-down` made the relay close first 5/5 with 5/5 answers and no
RST. `shut-close` reset 5/5 and `linger=0` aborted 5/5, so neither was taken.

`kong_addr` is unchanged: the capability probe keeps `shut-none`, because Funnel answers 502 to
a half-closed request (measured 2026-10-15).

## Consequences

- A flow the VM ends first (a `Connection: close` answer, a server-closed WebSocket) still
  leaves the TIME_WAIT on the VM and can still stall. If that rate matters, point the relay at
  the VM's WAF on :8443 (kernel TCP) rather than adding socat options.
- The relay's netns now holds the TIME_WAITs: about 28,000 ports / 60 s, roughly 470 new
  connections/s to the VM, against about 3/s today.
- The relay reads its routes once, at start. A live change takes a relay restart, and
  `grobase-link.service` and its heal timer rewrite the routes from the checkout they run in.

## Risk verdict

PROCEED-WITH-CONDITIONS, 2026-11-06 (devil, LS1–LS12): blast radius 4, reversibility 1, cost on
failure 2, confidence 3. The conditions cover the push, this record, a preflight, measuring the
restart, `make link-verify`, a realtime reconnect check, a 10-minute stall measurement with its
pass/rollback thresholds, the VM-closed-first residual, and a rollback that strips the option.
