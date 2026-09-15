# Network Segmentation — grobase (the BaaS backend)

> A four-plane Docker bridge topology enforces that a compromised public-edge container (WAF, Kong) cannot open a raw TCP socket to any data-plane engine (Postgres, MySQL, MongoDB, Redis, MinIO), because those engines are exclusively attached to an `internal: true` bridge that the public edge never joins.

## What it is (the concept)

**Network segmentation** partitions a system into isolated zones whose members can communicate only with peers on a shared segment, with all cross-zone traffic forced through explicit, auditable **chokepoints**. In a container context, Docker implements this through **named bridge networks**: two containers can reach each other if and only if they share at least one bridge. Declaring a bridge `internal: true` strips it of any host or WAN gateway, so containers on that bridge cannot initiate outbound connections outside the Docker network — and containers that are *not* attached to that bridge cannot initiate inbound ones. The resulting topology is a **default-deny posture** between zones, not a default-allow one.

## What it defends against

See [network-segmentation](../../attack/network-segmentation.md). The direct threat in grobase's context is **lateral movement after edge compromise**: an attacker who achieves remote code execution inside the WAF (`waf`) or API gateway (`kong`) container — the services with public internet exposure — would, on a flat single-bridge stack, be able to open a raw TCP socket to `postgres:5432`, `redis:6379`, `mongo:27017`, or any other data engine, bypassing the query-router's per-request owner-scoping, the permission-engine ABAC PDP, and RLS entirely. Segmentation removes that option by ensuring the public-edge containers are not co-attached to the data-plane bridge.

## How grobase implements it

The control is a standalone Compose **overlay** (`docker-compose.netseg.yml`, never folded into the base) that assigns every service to exactly the bridge(s) its plane requires — and no others.

**[`apps/grobase/orchestrators/compose/docker-compose.netseg.yml`](../../../../apps/grobase/orchestrators/compose/docker-compose.netseg.yml)** — the four-bridge declaration:

```yaml
networks:
  net-edge:
    driver: bridge
    name: ${NETSEG_PREFIX:-netseg}-edge
  net-control:
    driver: bridge
    name: ${NETSEG_PREFIX:-netseg}-control
    internal: true   # control plane has no host/WAN egress
  net-data:
    driver: bridge
    name: ${NETSEG_PREFIX:-netseg}-data
    internal: true   # engines are internal-only: no host/WAN egress
  net-observ:
    driver: bridge
    name: ${NETSEG_PREFIX:-netseg}-observ
    internal: true
```

The four planes and their memberships, as declared in the same file (lines 86-152):

| Plane | Services | Bridges |
|---|---|---|
| **Edge** (public internet) | `waf`, `kong`, `studio`, `playground`, `gotrue`, `postgrest`, `realtime` | `net-edge` only (kong also on `net-control`) |
| **Control** (tenancy, auth, orchestration) | `permission-engine`, `orchestrator`, `webhook-dispatcher`, `function-scheduler`, `vault` | `net-control` only |
| **Data** (engines) | `postgres`, `mysql`, `mariadb`, `cockroach`, `mssql`, `mongo`, `redis`, `minio` | `net-data` only |
| **Observability** | `prometheus`, `loki`, `promtail` | `net-observ` only (grafana also on `net-edge` for UI) |

The **only legal cross-plane edges** are the dual- or triple-attached **front-door routers**:

```yaml
query-router:
  networks: [net-edge, net-control, net-data]
data-plane-router-rust:
  networks: [net-edge, net-control, net-data]
adapter-registry-go:
  networks: [net-control, net-data]
tenant-control:
  networks: [net-control, net-data]
```

Any container that is not among these front-doors and needs to cross a plane boundary has no shared bridge with the destination and is refused at the kernel packet filter — no firewall rule required.

**Overlay discipline:** Compose `networks:` merges (adds) entries when an overlay is composed over a base; it cannot remove the base's `mini-baas` flat bridge. Consequently, composing the overlay over the live base is a **strict superset** — nothing that worked stops working. The hard-isolation step (dropping the flat bridge) is the documented production-cutover step proven safe by the gate but not applied to the default stack.

## How we know it is applied

**`scripts/verify/m66-netseg.sh`** is a self-contained Docker-first gate that proves the topology non-vacuously. It runs two independent arms:

**ARM 1 — parity proof** (static, no live stack needed):

```bash
BASE_NETS="$(docker compose -f "${BASE_COMPOSE}" config | awk … | sort -u)"
[[ "$(printf '%s\n' "${BASE_NETS}")" != "mini-baas" ]] && fail "parity broken"
# overlay must be a strict superset — mini-baas still present
echo "${MERGED_NETS}" | grep -qx "mini-baas" || fail "overlay DROPPED mini-baas"
# data/control bridges must be internal:true
grep -A3 'net-data:' "${NETSEG_COMPOSE}" | grep -q 'internal: true' || fail "net-data not internal:true"
```

**ARM 2 — live socket proof** (alpine stand-ins, isolated scratch project):

```bash
# REJECT (load-bearing — the gate's whole point):
if probe kong postgres 5432; then
  fail "SEGMENTATION FAILED: public-edge 'kong' OPENED a socket to postgres:5432"
fi
if probe prometheus postgres 5432; then
  fail "SEGMENTATION FAILED: observability 'prometheus' OPENED a socket to postgres:5432"
fi
# ALLOW (proves the listener is live — REJECTs are segmentation, not a dead socket):
probe query-router postgres 5432 || fail "ALLOW arm broken: query-router CANNOT reach postgres:5432"
```

The gate reads real TCP `nc -z` exit codes, not self-reported values. A gate that proved only the ALLOW arm would be vacuous; the REJECT arm is load-bearing.

**`scripts/verify/m140-network-controls.sh`** is a second, independent gate (ARM B) that re-runs the same segmentation proof alongside the WAF/OWASP-CRS blocking proof (ARM A), providing a combined network-controls regression suite at the ARM B level.

Both scripts use unique, collision-proof project and network names (`$$ + timestamp` suffix), run on isolated scratch volumes, and include `EXIT`-trap teardown — they never touch the live `mini-baas-*` stack.

## Reference

The OWASP Top 10 2021 category governing this control is **A05:2021 — Security Misconfiguration** (`https://owasp.org/Top10/A05_2021-Security_Misconfiguration/`). Network segmentation failures — specifically flat networks that allow unexpected inter-service connectivity — are listed under that category as a failure to "segment application architecture". The supplementary OWASP Docker Security Cheat Sheet (`https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html`) explicitly recommends `--internal` networks to prevent engine exposure.

*Note: both URLs were blocked by the local network policy at documentation time and could not be live-fetched; they are cited from training data (knowledge cutoff August 2025). Verify with a browser before publishing externally.*

## Residual risk / assumptions

1. **OPT-IN overlay, not the live default.** The running production stack (`docker-compose.yml` alone) uses a **single flat `mini-baas` bridge** where every service can reach every other service. The segmented topology is proven safe by `m66` and `m140` but is **not applied to the default boot** until a human executes the cutover step (dropping the flat bridge). Until cutover, this control exists only as a tested, deployable artefact — not a live enforcement.

2. **Compose merge cannot remove the base bridge.** Even when the overlay is composed over the base, the `mini-baas` bridge remains present (Compose cannot remove a network declared in the base). Full isolation requires a base-compose edit to drop the flat bridge, which is the production-cutover step gated by `m66`.

3. **Front-door containers remain attack surface.** `query-router` and `data-plane-router-rust` are intentionally triple-attached; a compromise of either one still grants data-plane access. The defense assumes those containers enforce per-request owner-scoping, ABAC policy, and RLS — that assumption is not this control's responsibility to enforce.

4. **Alpine stand-ins, not real binaries.** The gate proves bridge-level TCP reachability using `alpine:3.20` listeners (`nc -lk`). It does not test application-layer authentication on the real engines. Bridge membership is the control; the gate correctly isolates and proves exactly that.

5. **`internal: true` limits egress, not ingress to the Docker host.** Containers on an `internal` bridge cannot reach the host network or the internet, but a container on a non-internal bridge that is somehow co-attached to `net-data` (e.g. via a manual `docker network connect`) would bypass this control. Operational hygiene (no ad-hoc network attachments to production) is a required trust assumption.
