# A mail job awaiting another job inside its queue slot is out of scope

- Decided: 2026-11-04 · by devil (ruling on the account-mail fix, ADR 0048)
- Holds while: `createWorkQueue` runs a fixed number of workers shared by every mail job, and sign-in alerts travel in the same queue

## The concept

To keep two registrations for one address from overlapping, each job for that address awaits the previous job's completion
at the start of its own queue slot, through a Map from address to the last job's promise. The queue keeps two workers, so
different addresses still run side by side.

## Why not

It works, and it does not deadlock: the queue is FIFO, so a job holding a slot always has its predecessors started
(`scripts/auth/work-queue.mjs:51-63`, prismatica `3423773`). The cost is that a waiting job occupies a worker and does nothing.

- One address with two requests takes both workers while the first job runs. Simulated at 11 s sends, 8 addresses with
  3 requests each drain in 187 s against 143 s unchained, so an attacker's paired requests remove the throughput the design
  exists to keep (ADR 0048).
- A job that never settles stops all mail with two workers held, where today it costs one of two.
- Serial order needs no such wait: one worker gives it in one line, and a key inside the queue gives it with no worker held
  (143 s in the same model).

What would have to change: a queue that can spare a worker, meaning workers no longer shared with security mail, or a slot that
is released while a job waits. You would see it in `work-queue.mjs` no longer holding `running` across the await.

## Prior requests

- 2026-11-04 (the account-mail plan): the chain as Plan 2, with a Caveat for per-process scope.

## Reopen when

A job can wait on another without holding a worker. Until then, serial order per address goes inside the queue or comes from
one worker.
