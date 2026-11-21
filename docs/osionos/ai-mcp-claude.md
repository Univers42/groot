# Read your workspace from Claude over MCP

The osionos assistant service exposes a read-only MCP endpoint in public mode.
A personal access token (PAT) with the `read` scope lets Claude Code or
Claude Desktop read the workspaces you chose, and nothing else.

## What it is and is not

- Read only. Public mode refuses a mint that asks for `write_approval`
  (400 `scope_not_allowed`).
- The token is shown once, stored as a hash, expires (you pick the number of days) and
  is revocable at any time.
- The route accepts only the pinned public API host (`403 host_not_allowed`
  otherwise) and any request carrying an `Origin` header is refused
  (`403 origin_not_allowed`): it is for agents, not for web pages.
- It does not run the assistant, spend model budget or write to a page.

## URL

`https://<public API origin>/api/ai/mcp`

The API origin is the public `VITE_API_URL` (the `:10000` Funnel path of the
node), not the `:8443` app origin: `:8443/api/*` serves the app, not the API.

## Steps

1. In the osionos app, open the access-tokens panel and create a token: scope
   `read`, the workspaces Claude may read, a short expiry. Sign in again first
   if asked (a mint needs a session younger than ten minutes).
2. Copy the token now. It is never shown again. Keep it out of repositories and
   chat logs.
3. Add the server.

Claude Code:

```sh
claude mcp add --transport http osionos "https://<public API origin>/api/ai/mcp" \
  --header "Authorization: Bearer $OSIONOS_PAT"
```

Claude Desktop (`claude_desktop_config.json`, through the `mcp-remote` bridge):

```json
{
  "mcpServers": {
    "osionos": {
      "command": "npx",
      "args": ["mcp-remote", "https://<public API origin>/api/ai/mcp",
               "--header", "Authorization: Bearer ${OSIONOS_PAT}"],
      "env": { "OSIONOS_PAT": "<paste the token here>" }
    }
  }
}
```

4. Revoke the token from the same panel when you are done. The next call with
   it answers 401.

## Example

Filled from the live probe at go-live; no output is shown here until it exists.

```text
(pending live probe)
```

## Limits

- A token reads only the workspaces it was minted for, and only while you are
  still a member of them.
- Twenty live tokens per user at most.
- A tool call that needs `write_approval` is unavailable in public.
