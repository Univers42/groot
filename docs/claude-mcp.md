# Claude MCP for osionos

osionos exposes a first-party local MCP server for Claude Code at:

```bash
apps/osionos/app/scripts/osionos-mcp-server.mjs
```

The server uses stdio, so Claude Code launches it directly. It does not require an Anthropic API key. It talks to the existing osionos bridge and Fastify API surfaces instead of opening a direct database gateway.

## Local Claude Code

The server is registered locally with Claude Code as `osionos`:

```bash
claude mcp get osionos
```

Available tools:

- `osionos_status`
- `osionos_list_workspaces`
- `osionos_list_pages`
- `osionos_search_pages`
- `osionos_read_page`
- `osionos_create_page`
- `osionos_update_page`
- `osionos_append_to_page`
- `osionos_archive_page`

## Local Services

The bridge remains on `http://localhost:4000` by default. The MCP server expects the Fastify API on `http://localhost:4200` by default so it does not collide with the bridge.

Override URLs when needed:

```bash
OSIONOS_MCP_BRIDGE_URL=http://localhost:4000 \
OSIONOS_MCP_API_URL=http://localhost:4200 \
pnpm --dir apps/osionos/app mcp:claude
```

For local development, start the existing embedded API on the MCP port with the existing Notion Mongo container:

```bash
cd apps/osionos/app/src/shared/notion-database-sys
SHELL=/bin/sh \
PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" \
API_HOST=127.0.0.1 \
API_PORT=4200 \
JWT_SECRET=dev-secret-change-in-production \
OSIONOS_BRIDGE_SHARED_SECRET=dev-secret-change-in-production \
MONGO_URI='mongodb://notion_user:notion_pass@localhost:37017/notion_playground_db?authSource=admin' \
pnpm --filter @notion-db/api dev
```

## Hosted Connector Path

Claude web/mobile connectors cannot reach localhost. A Notion-style hosted connector for osionos should expose the same MCP tool surface over HTTPS and add OAuth or another user-scoped authorization flow. The local stdio server is the development and Claude Code path; the hosted connector is the production path.