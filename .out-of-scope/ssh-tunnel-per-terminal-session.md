# Reaching the user's shell by an ssh tunnel opened per session is out of scope

- Decided: 2026-11-01 · by devil (ADR 0041, Amendment 1)
- Holds while: the terminal runs on the user's own machine, behind a loopback-only osionos-node

## The concept

Instead of remembering the computer, "synchronize by tunneling (ssh) each time we open the session": every
time the dock opens a terminal, connect to the machine over ssh, so the browser never has to keep a
credential on the node.

## Why not

- A browser cannot speak ssh. Something must relay it, the bridge or a server, and that relay must hold a
  key that logs into the user's machine. That is a cloud-held credential to every user's computer, which
  ADR 0037 and the sovereignty rule (users' own machines, never a cloud OS) refuse.
- The user's machine would need an sshd reachable from that relay, in place of today's loopback-only port
  (`packages/osionos-node/cli.mjs:51` accepts private IPv4 listens only). That is a network attack surface
  where there is none today.
- It does not solve the complaint. The ssh credential has to survive a reload too, so it is "remember this
  computer" again, with a remote blast radius in place of a loopback one.
- ADR 0041 already refused the same shape: "relay the pty through the app's origin to the bridge".

## Prior requests

- 2026-11-01 (owner): proposed as the alternative to remembering the computer.

## Reopen when

The terminal targets a machine the user does not sit at, so the shell is remote by nature (for example a
server added in Settings › Machines with no osionos-node on it), and the ssh key stays on the user's
device, never on the bridge.
