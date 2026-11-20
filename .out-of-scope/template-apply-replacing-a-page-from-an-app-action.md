# Replacing a page's content from the `template.apply` app action is out of scope

- Decided: 2026-11-20 · by devil (template-dashboards ruling, TD14)
- Holds while: app-action `confirm` is static, and a replaced page body has no server-side version to restore from.

## The concept

The template-dashboards plan gives the `template.apply` app action an optional `pageId`. With it, the action replaces that page's content with a template, behind a simple confirm that appears only when the page has content. Button programs and automations could therefore "switch the page to another template".

## Why not

- `confirm` is a static field of the registry entry (`features/app-actions/model/actionRegistry.ts`). It cannot become "simple only when the page has content", and it cannot offer the Keep-a-copy / Replace / Cancel choice.
- Button programs call `runAppAction` (`services/button-program/runProgram.ts:219-236`). A button on a shared page that another user wrote could replace any page the clicker can edit, behind one boolean confirm.
- Undo exists only in the open editor's history (`useBlockHistory.ts:90`). It is cleared on navigation and reload. No server page-version history exists, so a replace started from an action is one-way.
- A new page from a template (no `pageId`) has none of these problems and stays in scope.

## Prior requests

- 2026-11-20 (osionos template-dashboards spec, line 150): `template.apply` with params `{ templateId, pageId? }`.

## Reopen when

Server-side page versions exist, and one restore brings back a replaced body after a reload.
