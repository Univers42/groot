# Granting operators tailnet access by login, group or autogroup is out of scope

- Decided: 2026-10-19 · by devil (ruling SEC3, Part B; grobase ADR 0002 C4)
- Holds while: baas and the other non-operator machines (c2r19s5, grobase) are untagged devices
  owned by the operator's own login

## The concept

The first draft of the C4 policy fragment: one rule
`{"action":"accept","src":["<operator login or group>"],"dst":["*:*"]}` for the operator's devices,
next to the bridge's `baas:8443` grant.

## Why not

- A login, group or `autogroup:member` source resolves to every untagged device of that login. That set
  includes c2r19s5 and **baas itself**, so the rule hands `*:*` to the VM that runs untrusted IDE code
  next to prod.
- It also contradicts the policy's own deny test for c2r19s5: either the console refuses the save, or,
  if the test does not resolve ownership, it passes vacuously.
- One host alias per operator device is the only source shape that names exactly the intended
  machines (SEC3 B3).

## Prior requests

- The plan sent to the devil on 2026-10-19 (`<operator device IPs or a group>`).

## Reopen when

baas and every non-operator device stop being untagged devices of the operator's login (tagged, or moved
to another owner).
