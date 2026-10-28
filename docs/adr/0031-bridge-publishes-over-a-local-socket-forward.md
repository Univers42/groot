# 0031. The bridge publishes over a local socket forward

- Status: accepted (devil PROCEED-WITH-CONDITIONS 2026-10-27, S1–S16)
- Date: 2026-10-28
- Deciders: owner, after the devil risk ruling on the publish-socket plan
- Numbered 0031 because 0029 is the latest ADR on develop and 0030 is assigned on another branch.

## Context

- Every osionos co-edit event is published by the bridge to the realtime gateway through the data
  center VM's Kong. The Tailscale route costs about 10 ms p50. Live warm measurements on
  2026-10-28 (3 runs of 80 samples) measured p50 11.8 ms and p90 14.7 ms.
- `make publish-socket` installs a host user unit that forwards the VM's Kong over `ssh -L` to
  `$XDG_STATE_HOME/osionos-publish/sock/kong.sock`. The local socket measured 0.43 ms p50.
- The bridge uses `REALTIME_PUBLISH_SOCKET` when it is set. It can fall back to
  `REALTIME_PUBLISH_URL` for an individual publish only when nothing was sent; a timeout is
  ambiguous because the gateway may already have accepted the event.
- Docker is rootful on this host. The bridge runs as `node`, uid 1000, which is also the host user
  that owns the forward's 0700 directory and 0600 socket. The existing modes therefore need no
  loosening.

## Decision

- Keep the host `ssh -L` forward installed by `make publish-socket`, with the VM's ssh host public
  key pinned from `HOST_KEY_FILE`. The unit uses strict host-key checking and recreates its local
  socket on reconnect.
- Add `docker-compose.publish-socket.yml` only when `OSIONOS_PUBLISH_SOCKET` is exactly `1`.
  `utils/mk/public.mk` layers it after `docker-compose.grobase-link.yml`, after any existing
  `PUBLIC_COMPOSE_EXTRA`, and before `docker-compose.public.yml`. With the flag unset or set to any
  other value, the compose file list is unchanged.
- The overlay sets `REALTIME_PUBLISH_SOCKET=/run/osionos-publish/kong.sock` and mounts
  `OSIONOS_PUBLISH_SOCKET_DIR` at `/run/osionos-publish:ro` in `osionos-bridge` alone. It mounts
  the directory, not the socket file: `StreamLocalBindUnlink` gives a reconnected socket a new
  inode, which a file bind mount would not follow. No other service receives the directory, and
  the overlay adds no TCP listener, relay or network alias.
- Fall back to the URL per publish only when nothing was sent: a connect error (`ENOENT`,
  `ECONNREFUSED`, `EACCES`, `ENOTSOCK`) sends that same publish over the URL at once. Any failure
  opens a 30 s breaker that routes every publish over the URL, then lets one probe try the socket.
  A publish that hits the 300 ms timeout is never re-sent.
- Operators opt in for a recreation with
  `OSIONOS_PUBLISH_SOCKET=1 OSIONOS_PUBLISH_SOCKET_DIR=<dir> make public-up`, using the directory
  printed by `make publish-socket`.

## Consequences

- With the opt-in unset, public mode keeps its previous compose file list and Tailscale publish
  path. With it enabled, the bridge container can reach only the read-mounted socket directory;
  reconnects remain visible because the mount follows the directory rather than one socket inode.
- An absent socket costs one failed connect: that publish goes over the URL immediately and the
  next 30 s skip the socket. A hung forward costs the one publish that hits the 300 ms timeout,
  then the same 30 s on the URL. The bridge's `/health` response exposes `publish_route` (route
  and errno class, never the path) so an operator can see which route is active.
- A timed-out publish is lost, never re-sent over either route. Retrying it could duplicate an event
  that the gateway accepted before the response was lost.
- A VM rebuild changes the host key that the forward pinned. After obtaining the new host public
  key over a trusted step, the operator must run `make publish-socket HOST_KEY_FILE=<fresh file>`
  again, then use the opt-in environment on the next `public-up`. Until then the pinned forward
  refuses the new host and the bridge falls back under the rules above.

## Rejected alternatives

- **Add `socat` with `TCP_NODELAY` to the relay.** Measurement on 2026-10-28 showed no gain: p50
  stayed about 12 ms before and after. It would also add another TCP hop without removing the
  Tailscale latency.
- **Publish directly from the client over WebSocket.** Gateway tokens carry no `exp`, so clients
  would receive a non-expiring publish credential.
- **Carry `/rest` over the same socket.** That would bypass the VM's WAF for service_role PostgREST
  calls, a different and unmeasured risk; see
  [the out-of-scope note](../../.out-of-scope/rest-over-publish-socket.md).
