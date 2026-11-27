# DRAFT: the osionos AI Hub tab folds into Settings; AI has one home

- Status: draft, untracked. Ruled by devil 2026-11-27, PROCEED-WITH-CONDITIONS AS1–AS12.
  Verdict record: `.claude/agent-memory/devil/osionos-ai-hub-into-settings-verdict.md`.
- Scope: osionos `feat/ai-settings-home`, commit 7009e7811 on 24dbc6b47.

## Context

The workspace had two settings surfaces: Settings, and an AI Hub tab (`kind: "ai-hub"`)
with its own overview, usage, routing, privacy, skills, memory and MCP server list. Three
of the privacy rows were mounted in both, and `SentimentSection` keeps per-instance
`loaded` state, so the two copies disagreed after a toggle. The MCP server list was
rendered only by the Hub.

## Decision

The Hub's sections move under Settings, each rendered once:

| Concern | Single mount (checked by `rg` on 7009e7811) |
| --- | --- |
| AS1 privacy rows (account context, web access, sentiment) | `AiSwitches.tsx` only |
| AS2 memory panel | `AiWorkspacePanels.tsx` only |
| AS3 MCP servers | `AiConnectionsSection.tsx:28` |
| AS11 usage read | `useUsage()` in `AiOverview.tsx:17` only (one `getUsage` per mount) |

A stored layout that still holds an `ai-hub` tab is migrated on read
(`layoutPersist.ts:196-210`): it becomes the Settings tab with the same `tabId`, or is
dropped when the tree already has one. The pane's active tab moves to that Settings tab.

## Consequences

- A saved Hub tab reopens Settings on **Profile**, not on the AI section: the layout model
  does not import `features/settings`, so it cannot name a section. One extra click, once,
  per browser that had the tab open.
- Nothing else reads `ai-hub`: the only ingress for stored tabs is `loadLayout`; navigation
  history is in memory; there is no server-side layout sync.

## Rejected

- Keeping the Hub as a read-only overview: a second home is the defect being removed.
- Landing migrated tabs on the AI section: needs the layout model to import a feature
  module, which inverts the layer order for a one-time click.
