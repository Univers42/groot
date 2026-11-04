# A shipped osionos Connector that trusts the beta or other non-production app origins is out of scope

- Decided: 2026-11-01 · by devil (ADR 0042, C-3) · **overridden by the owner the same day: the beta ships trusted** (ADR 0042, "Owner override of C-3")
- Holds while: the beta runs unreviewed develop pushes and is reachable from outside the owner's control

## The concept

Build the Connector with the same `--app-origin` list as the owner's node, production plus the beta
(`https://baas-beta.tail10f2ea.ts.net`), so testers and the owner's colleague can use the terminal from
the beta.

## Why not

- Any trusted origin can read an unpaired Connector's pairing code from the frame and claim it with any
  account. That binds the user's computer to that account and gives it a shell.
- The beta is rebuilt on every develop push and is public through Funnel (groot bb25044e, ADR 0040, and
  ADR 0041 W15). Trusting it means every develop commit can take over every installed computer.
- W15 is the owner's own risk, on the owner's own machine (`~/.config/systemd/user/osionos-node.service`).
  It does not extend to other people.
- Local opt-in stays allowed: an explicit config file the installer never writes.

## Prior requests

- 2026-11-01 (owner, W15): keep the beta trusted on the owner's node. Accepted for that one machine.

## Reopen when

Develop deploys only after a review gate equal to production's, and the beta's origin is limited to named
users. Both can be checked: the beta update script requires an approved review, and the edge refuses
unauthenticated visitors.
