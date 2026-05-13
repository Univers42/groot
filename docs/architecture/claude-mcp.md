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

The root Docker stack exposes the browser-facing bridge/API through the local TLS proxy at `https://localhost:4000`. Inside Docker and MCP stdio processes, the bridge still speaks plain HTTP at `http://localhost:4000`; keep that internal URL for Claude MCP registrations. In the root Docker stack, `http://localhost:4200` belongs to the Calendar bridge, so osionos MCP should not use that port unless you intentionally start a separate osionos API there.

Override URLs when needed:

```bash
OSIONOS_MCP_BRIDGE_URL=http://localhost:4000 \
OSIONOS_MCP_API_URL=http://localhost:4000 \
PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" \
node apps/osionos/app/scripts/osionos-mcp-server.mjs
```

Register the server with Claude Code from the repository root:

```bash
PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" \
pnpm --dir apps/osionos/app install --frozen-lockfile

PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" \
claude mcp add osionos \
	-e OSIONOS_MCP_BRIDGE_URL=http://localhost:4000 \
	-e OSIONOS_MCP_API_URL=http://localhost:4000 \
	-- bash -lc 'PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"; cd "apps/osionos/app"; exec node scripts/osionos-mcp-server.mjs'
```

On hosts where the global `claude` command is launched by an unsupported Node runtime, put the project Node 22 runtime first before invoking Claude:

```bash
PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" claude --version
```

The browser Agent page calls the root Docker `osionos-bridge` service, which runs Claude Code inside the container. By default the compose stack mounts the host Node 22 Claude install and Claude config from:

```bash
CLAUDE_NODE_HOME="$HOME/.nvm/versions/node/v22.22.2"
CLAUDE_HOME="$HOME/.claude"
CLAUDE_CONFIG_FILE="$HOME/.claude.json"
```

Override those variables if Claude Code is installed or authenticated somewhere else on a teammate machine.

For local development, start the existing embedded API on the MCP port with the existing Notion Mongo container:

```bash
cd apps/osionos/app/src/shared/notion-database-sys
SHELL=/bin/sh \
PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH" \
API_HOST=127.0.0.1 \
API_PORT=4210 \
JWT_SECRET=dev-secret-change-in-production \
OSIONOS_BRIDGE_SHARED_SECRET=dev-secret-change-in-production \
MONGO_URI='mongodb://notion_user:notion_pass@localhost:37017/notion_playground_db?authSource=admin' \
pnpm --filter @notion-db/api dev
```

## Hosted Connector Path

Claude web/mobile connectors cannot reach localhost. A Notion-style hosted connector for osionos should expose the same MCP tool surface over HTTPS and add OAuth or another user-scoped authorization flow. The local stdio server is the development and Claude Code path; the hosted connector is the production path.