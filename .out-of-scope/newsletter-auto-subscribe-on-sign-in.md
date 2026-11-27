# A client-side automatic newsletter subscribe on sign-in is out of scope

- Decided: 2026-11-23 · by devil (prismatica#87 ruling, `scratch/me-d/RULING-newsletter-sync-87.md`)
- Holds while: the gateway has no authenticated, deduplicated opt-in path

## The concept

When someone signs in to the portal, subscribe them to the newsletter from the browser if their
stored consent says so, with a fresh Turnstile token or with none.

## Why not

- Without a token the gateway refuses the call (that was the bug in #87: one
  `newsletter_turnstile_failed` row per sign-in, nobody subscribed).
- With a token it works on every sign-in, so a confirmed subscriber gets a new confirmation mail
  each time, and each mail counts toward the shared cap of 3 per hour per target.

## What would have to change

The gateway gets an opt-in path that takes the address from the verified session, fires only once a
session exists, and sends nothing while a pending or confirmed row exists (NS12–NS15), deployed under
its own ruling. VP21 forbids a gateway deploy for this today.
