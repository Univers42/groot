// Audit trail for the IDE socket proxy (devil A9/S6): one JSON line per container create, start,
// stop and remove the proxy forwards, or refuses at the start gate. Lines go to stdout, so
// `docker logs osionos-ide-socket-proxy` carries them. Fields are the operation, the box digest
// (the 32 hex of the container name, never the owner or workspace id), the uid, a reason and the
// daemon's status. No env values and no body content are ever written.
//
// Caveat: retention is the operator's docker log config, not this file's: with the default
// json-file driver and no max-size/max-file the log is unbounded, with them set it rotates away
// the 30 days the verdict asks for. `reason` is client-asserted (header x-ide-reason, a short
// slug) and defaults to "unspecified", so it labels a line and proves nothing. The uid of a
// start/stop/remove is known only for a box created since this process started (the ledger maps
// owners to uids, not boxes), otherwise null. A line is written when the daemon answers, so a
// request that dies in flight leaves none.

const BOX_NAME = "(ide|ideinit)-([0-9a-f]{32})";
const ROUTES = [
  ["POST", new RegExp(`^/(?:v[\\d.]+/)?containers/create\\?name=${BOX_NAME}$`), "create"],
  ["POST", new RegExp(`^/(?:v[\\d.]+/)?containers/${BOX_NAME}/start$`), "start"],
  ["POST", new RegExp(`^/(?:v[\\d.]+/)?containers/${BOX_NAME}/stop(?:\\?.*)?$`), "stop"],
  ["DELETE", new RegExp(`^/(?:v[\\d.]+/)?containers/${BOX_NAME}(?:\\?.*)?$`), "remove"],
];
const REASON_RE = /^[a-z][a-z0-9-]{0,31}$/;

function audited(method, path) {
  for (const [routeMethod, re, op] of ROUTES) {
    const match = routeMethod === method ? re.exec(path) : null;
    if (match) return { op, kind: match[1] === "ideinit" ? "init" : "box", box: match[2] };
  }
  return null;
}

export function createAudit({ out = process.stdout, now = () => new Date() } = {}) {
  const uidByBox = new Map();

  /** Write the line for this request when it is an audited operation; a no-op otherwise. */
  function record(method, path, { status, headers = {}, body, reason } = {}) {
    const target = audited(method, path);
    if (!target) return;
    const key = `${target.kind}-${target.box}`;
    if (target.op === "create") {
      const uid = Number(body?.Labels?.["osio.ide.uid"]);
      if (Number.isInteger(uid)) uidByBox.set(key, uid);
    }
    const asserted = String(headers["x-ide-reason"] ?? "");
    const line = { ts: now().toISOString(), op: target.op, kind: target.kind, box: target.box, uid: uidByBox.get(key) ?? null, reason: reason ?? (REASON_RE.test(asserted) ? asserted : "unspecified"), status };
    if (target.op === "remove") uidByBox.delete(key);
    out.write(`${JSON.stringify(line)}\n`);
  }

  return { record };
}
