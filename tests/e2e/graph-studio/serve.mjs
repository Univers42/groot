// Serves the graph_render pack the way osionos-app does, and nothing else: the pack under
// /graph-studio/<pin>/ (wasm as application/wasm, a missing file 404, never an SPA fallback), and
// at / a bare host page whose <meta name="graph-studio-base"> names that base, as osionos's
// index.html does. The page carries no script: the spec drives it.
//   GS_PACK_DIR=<fetch-pack.sh output> GS_PIN=<gitlink> GS_PORT=4317 node serve.mjs
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";

const dir = process.env.GS_PACK_DIR;
const pin = process.env.GS_PIN;
const port = Number(process.env.GS_PORT ?? 4317);
if (!dir || !/^[0-9a-f]{40}$/.test(pin ?? "")) throw new Error("set GS_PACK_DIR and GS_PIN (40 hex)");

const base = `/graph-studio/${pin}/`;
const TYPES = {
  ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json",
  ".css": "text/css", ".map": "application/json",
};
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>graph-studio contract host</title>
<meta name="graph-studio-base" content="${base}">
</head><body style="margin:0"><div id="host" style="width:900px;height:600px"></div></body></html>
`;

createServer(async (req, res) => {
  const path = new URL(req.url ?? "/", "http://localhost").pathname;
  if (path === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(PAGE);
    return;
  }
  const name = path.startsWith(base) ? path.slice(base.length) : "";
  const type = TYPES[name.slice(name.lastIndexOf("."))];
  if (!/^[\w.-]+$/.test(name) || type === undefined) {
    res.writeHead(404).end();
    return;
  }
  let body;
  try {
    body = await readFile(join(dir, name));
  } catch {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "content-type": type }).end(body);
}).listen(port, "127.0.0.1", () => console.log(`graph-studio contract host on :${port}, base ${base}`));
