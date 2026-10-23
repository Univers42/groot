// POST /osio/v1/uid {"owner":"<uuid>"} -> {"uid":<n>}: the ide-server asks for an owner's uid
// before it creates a box (ADR 0011, option b). Answered here and never forwarded to the daemon;
// /osio/ cannot collide with the Docker API, whose paths start with /_ping or /vN.N/. Allocation
// binds the uid in the ledger, so it happens at box create time and a page load cannot burn one.
// Caveat: the proxy cannot tell callers apart on the control net, so any caller that reaches it
// can allocate (it needs only a UUID); 40 000 owners exhaust the range. The network is the gate.

import { isUuidLike } from "./create-shape.mjs";

export const UID_PATH = "/osio/v1/uid";
const BODY_CAP = 1024;

function reply(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

export function handleUidRequest(req, res, ledger) {
  const chunks = [];
  let size = 0;
  req.on("data", (chunk) => { size += chunk.length; if (size <= BODY_CAP) chunks.push(chunk); });
  req.on("end", async () => {
    if (size > BODY_CAP) return reply(res, 413, { message: "ide-socket-proxy: body too large" });
    let owner;
    try { owner = JSON.parse(Buffer.concat(chunks).toString("utf8")).owner; } catch { owner = undefined; }
    if (!isUuidLike(owner)) return reply(res, 400, { message: "ide-socket-proxy: owner must be a uuid" });
    try {
      reply(res, 200, { uid: await ledger.allocate(owner) });
    } catch (error) {
      reply(res, 503, { message: `ide-socket-proxy: uid unavailable (${error?.reason ?? "error"})` });
    }
  });
}
