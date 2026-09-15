# Denial of Service (DoS/DDoS)

> An attack that deliberately exhausts a system's resources — bandwidth, memory, CPU, or connection
> slots — so that legitimate users cannot reach the service.

## What it is

A Denial of Service attack is any deliberate action whose primary goal is to make a target system
unavailable rather than to exfiltrate or corrupt data. The simplest form originates from a single
host; a *Distributed* DoS (DDoS) orchestrates thousands or millions of compromised machines
(a botnet) to overwhelm a target at a scale no single attacker could achieve alone. Attacks can be
volumetric (saturating the network pipe), protocol-level (exploiting TCP/IP state-machine weaknesses),
or application-layer (sending semantically valid but resource-expensive requests). Because HTTP is
stateless and application endpoints vary widely in cost, application-layer DoS is particularly hard
to distinguish from legitimate heavy traffic. All variants share the same outcome: degraded or
complete loss of service for real users.

## How the attack works

1. **Reconnaissance.** The attacker identifies a choke point — a costly database query, a file
   upload endpoint, a WebSocket handshake, a TLS negotiation step — that consumes significantly
   more server resources than the corresponding client cost.
2. **Amplification / botnet assembly.** For volumetric DDoS, the attacker enlists reflectors
   (open DNS resolvers, NTP servers, misconfigured memcached instances) that will respond to
   spoofed source addresses, returning far more traffic than was sent. For application-layer DoS
   a botnet of compromised IoT devices or cloud VMs suffices.
3. **Flood initiation.** Traffic or crafted requests are sent continuously toward the target.
   For application-layer attacks each request appears structurally valid, bypassing simple
   IP-block rules.
4. **Resource exhaustion.** The server's thread pool, connection table, memory heap, or uplink
   fills to capacity. Legitimate requests are queued then dropped; the service appears down or
   unacceptably slow.
5. **Sustained pressure.** Attackers rotate source IPs, adjust request patterns, and adjust
   attack vectors to evade reactive mitigations.

**Illustrative example — slow-read / low-and-slow pattern:**

```http
GET /api/search?q=expensive-full-text-query HTTP/1.1
Host: example.internal
Connection: keep-alive
# Client advertises a tiny TCP receive window (e.g. 1 byte),
# forcing the server to hold the response socket open for minutes
# while legitimate worker threads are exhausted.
```

This pattern does not require large bandwidth; a few hundred slow connections can stall a naive
server with a bounded thread pool (`worker_connections` or equivalent).

## Real-world impact

In September 2016, the security journalism site KrebsOnSecurity was struck by what Akamai reported
as the largest DDoS attack they had then recorded — peaking between 620 and 665 Gbps. Unusually, the
volume came not from amplification reflectors but from a direct botnet of compromised IoT devices
(cameras, DVRs) running the *Mirai* malware. The attack forced Akamai to drop the site from its
free-tier protection because absorbing the traffic cost exceeded the commercial threshold, leaving
the site unreachable for days until Google's Project Shield absorbed it. The incident demonstrated
that commodity consumer hardware, en masse, can produce nation-state-scale disruption with no
exploited protocol amplification required.
Source: Brian Krebs, *KrebsOnSecurity Hit With Record DDoS* (21 Sep 2016) —
<https://krebsonsecurity.com/2016/09/krebsonsecurity-hit-with-record-ddos/>

## OWASP classification

OWASP addresses this attack class under the **Denial of Service Cheat Sheet**, which catalogues
resource exhaustion vectors across the network, transport, and application layers and provides
prescriptive mitigations for each.

Reference: [Denial of Service — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html)

## How defenders stop it

- **Rate limiting and throttling** — enforce per-IP and per-user request caps at the edge, not
  only inside the application; apply graduated back-off before hard rejection.
- **Connection and timeout hygiene** — set aggressive read/write/idle timeouts on every socket;
  limit maximum concurrent connections per source address.
- **Request queue depth limits** — bound in-flight request queues; shed load with `503` early
  rather than queuing until OOM.
- **Input cost controls** — cap query complexity (GraphQL depth/breadth limits, pagination
  enforcement, full-text search token limits) so expensive operations cannot be triggered without
  authentication or credits.
- **Upstream ingress filtering** — use a CDN or DDoS-scrubbing provider to absorb volumetric
  floods before they reach origin; enable BGP Blackholing for severe volumetric events.
- **Anycast and geographic load distribution** — spread capacity so that a regional flood does not
  kill the global service.
- **CAPTCHAs and proof-of-work challenges** — impose a client-side cost for unauthenticated
  high-frequency paths to raise attacker overhead.
- **Alerting and circuit breakers** — instrument error rates and latency percentiles; trip a
  circuit breaker that short-circuits the expensive code path and returns cached/static content
  when thresholds are breached.
- **SYN cookies and TCP hardening** — enable kernel-level SYN-cookie protection to resist
  SYN-flood exhaustion of the half-open connection table.

In this project, see the defenses: [grobase](../defense/grobase/denial-of-service.md),
[osionos](../defense/osionos/denial-of-service.md),
[osionos-bridge](../defense/osionos-bridge/denial-of-service.md),
[opposite-osiris](../defense/opposite-osiris/denial-of-service.md),
[auth-gateway](../defense/auth-gateway/denial-of-service.md),
[mail-calendar](../defense/mail-calendar/denial-of-service.md).

## References

- OWASP Cheat Sheet Series — Denial of Service:
  <https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html>
- Brian Krebs, "KrebsOnSecurity Hit With Record DDoS," *KrebsOnSecurity*, 21 Sep 2016:
  <https://krebsonsecurity.com/2016/09/krebsonsecurity-hit-with-record-ddos/>
