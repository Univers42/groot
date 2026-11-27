# An AI "bypass" mode that auto-runs MCP tool calls is out of scope

- Decided: 2026-11-22 · by devil (ruling `/mnt/storage/dlesieur/scratch/me-d/RULING-ai-modes.md`, draft `docs/adr/DRAFT-ai-modes-ruling.md`)
- Holds while: an MCP call cannot be undone and its arguments are built from workspace text

## The concept

A fifth assistant mode, `bypass`, in which every tool call the assistant makes runs without an approval card, including `mcp_call` to the user's connected third-party MCP servers, so long agent tasks run end to end with no clicks.

## Why not

- No inverse. `mcpClient/decide.ts` `runApprovedMcpCall` acts on a third-party system; nothing reverses it. The design's own G4 requires an undo for every auto-applied action.
- Exfiltration through arguments. The arguments are composed by the model from what it read, including pages other members write (taint covers only web and MCP today, `apps/osionos/app/services/osionos-ai/src/mcpClient/taint.ts`). A "read-only" tool still carries its arguments out; `readOnlyHint` is declared by the server, not verified.
- The gain is one call: the output taints the conversation (C286), so every later write in the turn is a card anyway.
- What would have to change: the user pins individual tools and classifies them read-only themselves; arguments pass the C356 WorkspaceTextLedger guard so no workspace text leaves; the output still taints; and a new devil ruling accepts it.

## Prior requests

- 2026-11-22 (user, via the ai-modes design): bypass mode with auto `mcp_call`. Refused; `accept_edits` and `auto` proceed with conditions for page writes only.

## Reopen when

A per-tool user pin and an argument guard against workspace text both exist in code, or the MCP client gains a tool class with a real inverse.
