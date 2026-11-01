# Giving the browser the VS Code server's connection token is out of scope

- Decided: 2026-10-30 · by devil ([ADR 0034](../docs/adr/0034-the-ide-runs-on-vs-codes-server-behind-a-non-public-node-proxy.md), condition C5)
- Holds while: a VS Code server on a connected machine runs with the owner's full user rights
- Note 2026-10-30: under the socket-mode amendment (ADR 0034) the server has no token at all. This record governs any return to a token mode.

## The concept

Pass the server's `--connection-token` to the osionos client: in the page URL (as the 2026-10-30 spike did,
`vscode-spike/src/main.ts:65`), in `connectionToken`, or as the `vscode-tkn` cookie the server sets itself. The
client then talks to the server with the same credential VS Code's own web client uses.

## Why not

- The token is a bearer credential for full code execution on the machine, and it never expires.
- The server sets it as a 7-day `SameSite=Lax` cookie on its root path (`server-main.js`, code-server 4.138.0).
- In a URL, it lands in history, logs and `Referer`.
- In the browser, any same-origin script reads it or rides it. The app origin renders embeds framed with `allow-same-origin` (`EmbedFrame.tsx:39`) and user content.
- The bridge proxy injects it on the loopback hop instead. The browser holds only a 15-minute, `HttpOnly`, node-bound capability that a sudo grant mints.

## Reopen when

The server's token stops being a long-lived full-rights credential, meaning it is bound to a scope or to an
expiry the server enforces. Re-decide from scratch, with a devil ruling.
