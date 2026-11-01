# Serving `/api/node/*` (the VS Code server proxy) on the public, Funnel-fronted origin is out of scope

- Decided: 2026-10-30 · by devil ([ADR 0034](../docs/adr/0034-the-ide-runs-on-vs-codes-server-behind-a-non-public-node-proxy.md), condition C8)
- Holds while: the proxied servers run with the owner's full user rights and the app origin renders untrusted content

## The concept

Reach the laptop and the VM from the hosted osionos web app, the one anyone can open. ADR-006 decision 6 says
"the bridge's `/api/node/:id` proxy on the app's origin", and the public app is the obvious reading.

## Why not

- A breach of this proxy gives code execution on every connected machine, including the VM that holds grobase prod keys.
- On the public origin, the proxy sits beside every public bridge route and is reached from the internet:
  - its only remaining barriers are a credential check and an origin check;
  - one same-origin XSS or one proxy bug is a host compromise.
- The 2026-10-19 BYO ruling already keeps the IDE secret off the Funnel bridge (C-S2). ADR 0022 keeps the public bundle IDE-less (N1/N2).
- The non-public tailnet origin limits who can reach the proxy to the owner's devices (C-S8).

## Reopen when

The servers behind the proxy no longer run with full user rights, meaning they are isolated per session, and the
proxy has passed the C7 refusal suite on a non-public origin for at least one release. Re-decide from scratch,
with a devil ruling.
