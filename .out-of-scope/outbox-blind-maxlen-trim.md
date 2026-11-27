# Out of scope: a blind MAXLEN on the outbox and saga streams

- Ruled: devil, 2026-11-24 (draft ADR `docs/adr/DRAFT-grobase-killswitch-ruling.md`, condition KS16).
- Asked for: cap `outbox.<table>` and `saga.*` Redis streams with a fixed `MAXLEN` so payload copies age out.
- Refused because: both streams feed consumer groups (webhooks `webhooks/streams.go:52`, functriggers `functriggers/dispatcher_streams.go:55`). A cap below a group's lag deletes entries that group has not yet read, so webhooks and function triggers that were never delivered are lost without an error.
- Instead: trim by `MINID` at or below the oldest un-ACKed id across every group, or use a `MAXLEN` sized from measured lag plus an alarm on lag (KS16, KS23).
- What would change the answer: the streams have no consumer group, or every consumer re-reads from the `outbox_events` table and never from the stream.
