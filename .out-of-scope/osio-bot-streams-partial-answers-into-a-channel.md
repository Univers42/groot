# Streaming a bot answer into a shared channel before it is final is out of scope

- Decided: 2026-11-21 · by devil (osio bot ruling, `docs/adr/DRAFT-osio-bot-ruling.md`, OB12)
- Holds while: any bot-row guard (L0, context change, trigger edit, asker access, page audience) can only be decided on the finished answer

## The concept

To make the in-app bot feel fast, insert its chat message as `pending` when the run starts, update it with
`message_updated` events as tokens arrive (≥ 250 ms apart), and mark it done at the end. Everyone in the
channel watches the answer being written.

## Why not

- Every guard on a bot answer runs on the final text: `refuseChangedContext`, `readLiveTrigger` and L0 in mode
  `on` (`apps/osionos/app/scripts/bridge-chat-ai.mjs:150-161`), and the asker-access recheck
  (`services/osionos-ai/src/runs/upstream.ts:313-315`). Partial text broadcast by realtime is read before any of
  them. The design's fallback ("back to the private draft") runs after readers have already seen it.
- A streamed row is edited many times, but C437 says nobody edits a bot answer (`scripts/bridge-chat.mjs:179`).
  Runs that start meanwhile read the partial text, and each later edit trips their `context_changed` refusal
  (`bridge-chat-ai.mjs:120-127`).
- Speed is met without it: the asker streams privately, and the channel gets a textless "answering" event.
- What would change the answer: every guard becomes decidable **before** the first token is published (for
  example, all page reads finish before the answer step and the audience recheck passes), and L0 gets a
  prefix-safe incremental mode whose retraction semantics the user accepts.

## Prior requests

- 2026-11-21 (osio bot design draft, phase 1 "Streaming"): proposed, refused.

## Reopen when

The guards above can all run before the first token and a prefix-safe L0 exists, shown by tests that block a
violating answer before any `message_updated` leaves the bridge.
