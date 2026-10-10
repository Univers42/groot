# Architecture study

Short, evidence-backed docs for rebuilding a mental model of groot, grobase at the centre.
Start with doc 00: each later doc zooms into one box of its maps.

Rules these docs follow: every arrow comes from code or config (file:line); inferred claims say
**GUESS**; each doc names the pins it was checked against. When code and an older doc disagree,
the code wins and the drift is noted.

| # | Doc | Status |
|---|---|---|
| 00 | [Context map](00-context-map.md) | done |
| 01 | local-https-proxy (nginx TLS edge) | planned |
| 02 | WAF + Kong | planned |
| 03 | tenant-control | planned |
| 04 | adapter-registry | planned |
| 05 | Data plane: Rust router + TS query-router | planned |
| 06 | Engine adapters | planned |
| 07 | Realtime | planned |
| 08 | GoTrue + PostgREST | planned |
| 09 | Async backbone: orchestrator, outbox, webhooks | planned |
| 10 | auth-gateway | planned |
| 11 | opposite-osiris web | planned |
| 12 | osionos app | planned |
| 13 | osionos-bridge | planned |
| 14 | mail + mail-bridge | planned |
| 15 | calendar + calendar-bridge | planned |
| 16 | drawnosaurus | planned |
