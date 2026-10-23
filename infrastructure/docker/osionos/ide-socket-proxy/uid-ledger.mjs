// The owner<->uid ledger: the one place that says which uid an owner's volumes belong to.
// One JSON line per binding ({"owner":"<uuid>","uid":20000}) in a file on a named volume of the
// plane (never the image, never a tmpfs). The proxy hands out uids and refuses any box or init
// create that disagrees with a binding (ADR 0011, verdict A1).
//
// Writes: whole file to a tmp name, fsync, rename over, fsync the directory, all serialized in
// this process. Memory is updated only after the write landed, so a failed write binds nothing.
// An unreadable or corrupt file refuses every create until the proxy restarts on a fixed file;
// only a missing file is "empty", logged once.
//
// Caveat: losing the ledger volume loses the bindings; the next create for each owner re-learns
// one by trust on first use, and nothing notices when it picks a uid that owns another user's
// files already on docker-ide. Owners compare as exact strings, so the same UUID in another case
// is another owner (it hashes to another home volume too). A line deleted by hand (GDPR runbook)
// frees its uid only when it was the highest, because allocation is max + 1: remove the volumes
// first. A bound that guards against a buggy bridge or DB, not a compromised ide-server.

import { open, readFile, rename } from "node:fs/promises";
import path from "node:path";
import { UID_MAX, UID_MIN, isUuidLike } from "./create-shape.mjs";

export const LEDGER_REFUSED = "ledger";
export const UID_BINDING_REFUSED = "uid-binding";

function isBindableUid(uid) {
  return Number.isInteger(uid) && uid >= UID_MIN && uid <= UID_MAX;
}

/** Parse the file into a Map owner -> uid, or throw on any line that is not exactly a binding or
 *  that repeats an owner or a uid. */
function parseLedger(text) {
  const byOwner = new Map();
  const owners = new Set();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    const entry = JSON.parse(line);
    const keys = entry && typeof entry === "object" ? Object.keys(entry) : [];
    if (keys.length !== 2 || !keys.includes("owner") || !keys.includes("uid")) throw new Error("not a binding");
    if (!isUuidLike(entry.owner) || !isBindableUid(entry.uid)) throw new Error("bad owner or uid");
    if (byOwner.has(entry.owner) || owners.has(entry.uid)) throw new Error("duplicate binding");
    byOwner.set(entry.owner, entry.uid);
    owners.add(entry.uid);
  }
  return byOwner;
}

async function loadLedger(file, log) {
  let text;
  try {
    text = await readFile(file, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      log(`ledger ${file} is missing: starting empty (first start; bindings are re-learned by trust on first use)`);
      return new Map();
    }
    log(`ledger ${file} is unreadable (${error?.code ?? "error"}): every create is refused`);
    return null;
  }
  try {
    return parseLedger(text);
  } catch (error) {
    log(`ledger ${file} is corrupt (${error?.message}): every create is refused`);
    return null;
  }
}

async function writeLedger(file, byOwner) {
  const tmp = `${file}.tmp`;
  const text = [...byOwner].map(([owner, uid]) => `${JSON.stringify({ owner, uid })}\n`).join("");
  const handle = await open(tmp, "w", 0o600);
  try {
    await handle.writeFile(text);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(tmp, file);
  const dir = await open(path.dirname(file), "r");
  try { await dir.sync(); } finally { await dir.close(); }
}

export function createLedger({ file, log = (line) => process.stderr.write(`[ide-socket-proxy] ${line}\n`) }) {
  let loaded = null;
  let chain = Promise.resolve();
  const ready = () => (loaded ??= loadLedger(file, log));
  // A rejected step must not poison the chain for the next caller.
  const serialized = (step) => {
    const run = chain.then(step);
    chain = run.catch(() => {});
    return run;
  };

  async function bind(byOwner, owner, uid) {
    const next = new Map(byOwner).set(owner, uid);
    await writeLedger(file, next);
    byOwner.set(owner, uid);
  }

  /** null when (owner, uid) agrees with the ledger (binding it when both are new), else the reason. */
  function admit(owner, uid) {
    return serialized(async () => {
      const byOwner = await ready();
      if (byOwner === null) return LEDGER_REFUSED;
      const bound = byOwner.get(owner);
      if (bound !== undefined) return bound === uid ? null : UID_BINDING_REFUSED;
      if ([...byOwner.values()].includes(uid)) return UID_BINDING_REFUSED;
      try { await bind(byOwner, owner, uid); } catch { return LEDGER_REFUSED; }
      return null;
    });
  }

  /** The owner's bound uid, or the next one above every bound uid (never a reused number). */
  function allocate(owner) {
    return serialized(async () => {
      const byOwner = await ready();
      if (byOwner === null) throw Object.assign(new Error("ledger unavailable"), { reason: LEDGER_REFUSED });
      const bound = byOwner.get(owner);
      if (bound !== undefined) return bound;
      const uid = [...byOwner.values()].reduce((top, bound) => Math.max(top, bound), UID_MIN - 1) + 1;
      if (uid > UID_MAX) throw Object.assign(new Error("uid range exhausted"), { reason: "exhausted" });
      try { await bind(byOwner, owner, uid); } catch { throw Object.assign(new Error("ledger write failed"), { reason: LEDGER_REFUSED }); }
      return uid;
    });
  }

  return { ready, admit, allocate };
}
