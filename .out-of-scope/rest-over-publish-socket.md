# Routing the bridge's /rest reads over the publish socket is out of scope

- Decided: 2026-10-27 · by devil (ADR 0031)
- Holds while: the bridge's `/rest` calls carry the service_role key and PostgREST sits behind the WAF only on the
  tailnet path

## The concept

The request: route the bridge's PostgREST reads through the same local ssh-forwarded socket that carries realtime
publishes, avoiding the tailnet hop for those reads too.

## Why not

- The socket bypasses the VM's WAF (ModSecurity), which every `/rest` call crosses today. One compromised bridge would
  gain unfiltered service_role SQL reach.
- The publish route carries only `/realtime/v1/publish` to a gateway that accepts nothing else from that key. That
  narrow route does not justify exposing the general PostgREST surface through the same WAF bypass.
- The latency case for `/rest` is unmeasured; the publish measurements do not establish a need for another route.

## Prior requests

- 2026-10-27 (the publish-socket plan).

## Reopen when

The bridge no longer uses service_role for these reads, the socket path provides WAF filtering equivalent to today's
tailnet path, and measurements show that the `/rest` latency justifies the change.
