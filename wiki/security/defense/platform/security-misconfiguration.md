# Security Misconfiguration — platform / infrastructure (cross-cutting)

> Docker network isolation and loopback-only host port binding ensure that backend datastores are never directly reachable from the host network, and that all dev services remain off the LAN by default.

## What it is (the concept)

**Security misconfiguration** is the failure to apply a secure baseline to infrastructure components — leaving services bound to unintended interfaces, exposing internal APIs through the wrong network plane, or allowing one stack to accidentally provision resources that belong to another. The **principle of least exposure** demands that every service binds only to the interface and port it legitimately needs. In containerised stacks the relevant boundaries are the Docker **network plane** (which containers can reach which peers by name) and the **host port binding** (which host interfaces a published port listens on).

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

In this stack, the realistic threats are: a frontend compose invocation accidentally re-upping — and thereby resetting or double-binding — backend engines (PostgreSQL, GoTrue, Kong, PostgREST, Realtime); backend datastore ports being reachable from the LAN on a shared developer machine or VirtualBox guest; and resource exhaustion of the proxy by an unconstrained memory allocation. Any of these misconfigurations would undermine the trust boundary between the frontend and backend planes.

## How platform implements it

**External network declaration — no accidental backend re-up.**
[`docker-compose.yml` lines 519-527](../../../../docker-compose.yml) declares the backend network as `external: true`:

```yaml
networks:
  mini-baas:
    name: mini-baas_mini-baas
    external: true
```

Because Docker Compose refuses to create an external network that does not already exist, `docker compose up` on the root (frontend) project will fail loudly rather than silently spawning a new, isolated `mini-baas` network that cannot reach the real backend containers. Frontends reach backend services (`mini-baas-kong`, `mini-baas-gotrue`, etc.) exclusively through container-name DNS on this shared network — never through published host ports.

**Loopback-only host port binding — LAN isolation by default.**
Every published port in [`docker-compose.yml` lines 9-17](../../../../docker-compose.yml) is prefixed with the variable `TRACK_BINOCLE_BIND_ADDR`, defaulting to `127.0.0.1`:

```yaml
ports:
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${OPPOSITE_OSIRIS_HOST_PORT:-4322}:4322"
  - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:${OSIONOS_APP_HOST_PORT:-3001}:3001"
  # … all frontend + bridge + auth-gateway ports follow the same pattern
```

This applies to the TLS proxy, the editor bridge, the auth gateway, the mail bridge, and the calendar bridge — every service with a host-facing port.

**VirtualBox auto-detection — controlled `0.0.0.0` widening.**
[`infrastructure/makes/common.mk` line 27](../../../../infrastructure/makes/common.mk) sets `TRACK_BINOCLE_BIND_ADDR` via a shell probe that reads `/sys/class/dmi/id/product_name` and checks the default gateway. Only when both conditions are true (DMI product name contains `VirtualBox` AND the default route is `10.0.2.2`) does it expand the bind address to `0.0.0.0`; on every other host it resolves to `127.0.0.1`:

```make
TRACK_BINOCLE_BIND_ADDR ?= $(shell \
  if [ -r /sys/class/dmi/id/product_name ] \
    && grep -qi 'VirtualBox' /sys/class/dmi/id/product_name 2>/dev/null \
    && ip route 2>/dev/null | grep -q 'default via 10\.0\.2\.2'; \
  then printf '0.0.0.0'; else printf '127.0.0.1'; fi)
```

**Proxy memory cap — resource exhaustion mitigation.**
[`docker-compose.yml` line 25](../../../../docker-compose.yml) places a hard `mem_limit: 128m` on the `local-https-proxy` (nginx:1.27-alpine), preventing an unconstrained proxy from monopolising host memory.

## How we know it is applied

These are not aspirational settings — they are in the committed `docker-compose.yml` consumed by `make all` via the `frontends-up` target on every developer machine and in CI. The `external: true` declaration is a **hard runtime gate**: if the `mini-baas` Docker project is not already running when `make frontends-up` executes, Docker Compose aborts with:

```
network mini-baas_mini-baas declared as external, but could not be found
```

This makes the isolation structural rather than procedural. The `TRACK_BINOCLE_BIND_ADDR` variable is exported (`export … TRACK_BINOCLE_BIND_ADDR`) in `common.mk` so it flows into every compose invocation without a developer needing to set it manually.

## Reference

[A05 Security Misconfiguration — OWASP Top 10:2021](https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/) classifies the failure to harden default configurations across all stack layers as a top-five web application risk. This control directly addresses the sub-categories of unnecessary features/services being exposed and default or unnecessarily permissive network bindings — both of which are explicitly called out in the OWASP A05 guidance.

## Residual risk / assumptions

- **No inbound firewall on the host.** The `127.0.0.1` binding relies on the OS loopback being non-routable; a host firewall misconfiguration or a rogue routing rule could still expose ports. The project does not ship or enforce a host-level `iptables`/`nftables` policy.
- **VirtualBox detection is heuristic.** The DMI + route probe can produce a false positive on a non-VirtualBox host that happens to use the `10.0.2.2` gateway subnet, widening the bind address unnecessarily.
- **Backend services' own port bindings are out of scope here.** The `mini-baas` stack owns its own `docker-compose.yml` (under `apps/grobase/`); its ports and network exposure are governed by that project's configuration, not by the controls documented here.
- **`TRACK_BINOCLE_BIND_ADDR` can be overridden.** Because it is a Make variable with `?=`, any caller that sets it in the environment or on the command line bypasses the default. There is no guard preventing `TRACK_BINOCLE_BIND_ADDR=0.0.0.0 make all` on a non-VirtualBox machine.
