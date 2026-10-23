# Per-topic realtime publish tokens for the osionos bridge are out of scope

- Decided: 2026-10-15 · by devil (Funnel-only ruling, ADR 0004)
- Holds while: the bridge is a server-side holder of JWT_SECRET and SERVICE_ROLE_KEY, and its publish
  token never leaves the server-to-server path.

## The concept

When the bridge publishes realtime events over the WebSocket, the request is to mint one token per topic,
with `namespaces: [<exact topic namespace>]`. The alternative is a single `namespaces: ["*"]` publisher
token on one persistent connection. The goal is that a leaked token can reach one topic, not all of them.

## Why not

- Every topic the bridge publishes has no "/": `user:<id>`, `feed:<ws>`, `chat:<ws>:<id>` and
  `objectdb:<id>`. Each topic is therefore its own namespace (`apps/grobase/infra/docker/services/realtime/
  realtime-agnostic/crates/realtime-core/src/types/topic_path.rs:63-65`). An exact grant means one token and
  one AUTH round per publish.
- A failed AUTH closes the socket (`realtime-gateway/src/ws_handler/handlers.rs:61-65`), which drops the
  publish queue.
- The minter already holds JWT_SECRET and SERVICE_ROLE_KEY. Both names are in the running bridge container's
  environment, measured 2026-10-15. Either one forges any token or reaches the REST publish route, and that
  route has no auth and no topic scoping (`rest_api.rs:103-111`, `kong.yml:296-300`). A per-topic token
  narrows the weakest credential in the process, not the strongest.
- The `"*"` token is bounded instead:
  - exp of 15 min at most;
  - `can_subscribe: false`;
  - sent only in the AUTH frame;
  - never logged.

  These are conditions FO21-FO22 of the 2026-10-15 verdict.

## Prior requests

- 2026-10-15 (coordinator, Funnel-only plan): proposed as the alternative to the `"*"` publisher.

## Reopen when

Any of these becomes true; each one makes the minted token the bridge's widest exposure:
- the bridge no longer has JWT_SECRET or SERVICE_ROLE_KEY in its environment;
- the publish token is handed to a browser or any other client;
- the target sets `REALTIME_PROTECTED_NAMESPACES` to a namespace the bridge must publish to. `"*"` cannot
  reach a protected namespace, so that namespace would need an exact grant.
