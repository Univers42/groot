// m50 parity suite — ops surfaces through the OFFICIAL PocketBase JS SDK:
// backups (create/list/delete), request logs (list/stats after traffic),
// crons (list + manual run), settings (read/patch round-trip). Run against
// binocle-one AND real PB; normalized outcomes diffed by the m50 gate.
// (Backup download + restore are exercised in the gate's binocle-only lane:
// real PB in a bare container has no supervisor to survive restore's exit.)

import PocketBase from "pocketbase";

const [base, suEmail, suPass] = process.argv.slice(2);
const pb = new PocketBase(base);
pb.autoCancellation(false);
const out = {};

async function step(name, fn) {
  try {
    out[name] = { ok: true, detail: await fn() };
  } catch (e) {
    out[name] = {
      ok: false,
      status: e?.status ?? 0,
      message: String(e?.response?.message ?? e?.message ?? e).slice(0, 120),
    };
  }
}

const TS = Date.now() % 100000;
const BK = `m50backup${TS}.zip`;

await step("setup-superuser", async () => {
  await pb.collection("_superusers").authWithPassword(suEmail, suPass);
  return { ok: true };
});

await step("traffic-for-logs", async () => {
  // a few requests so the log store has content (health is unauthenticated)
  for (let i = 0; i < 5; i++) await pb.health.check();
  await new Promise((r) => setTimeout(r, 2600)); // log writers batch ~2s
  return { ok: true };
});

await step("logs-list", async () => {
  const res = await pb.logs.getList(1, 5);
  return {
    pageOk: res.page === 1,
    hasItems: res.items.length > 0,
    shape: res.items.length > 0
      ? ["id", "level", "message", "data", "created"].every((k) => k in res.items[0])
      : false,
  };
});

await step("logs-stats", async () => {
  const stats = await pb.logs.getStats();
  return {
    isArray: Array.isArray(stats),
    shape: stats.length > 0 ? "date" in stats[0] && "total" in stats[0] : false,
  };
});

await step("logs-forbidden-for-guests", async () => {
  const anon = new PocketBase(base);
  try {
    await anon.logs.getList(1, 1);
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 401 || e?.status === 403 };
  }
});

await step("crons-list", async () => {
  const jobs = await pb.crons.getFullList();
  const ids = jobs.map((j) => j.id);
  return {
    hasOtpCleanup: ids.includes("__pbOTPCleanup__"),
    hasDbOptimize: ids.includes("__pbDBOptimize__"),
    hasLogsCleanup: ids.includes("__pbLogsCleanup__"),
    everyHasExpression: jobs.every((j) => typeof j.expression === "string" && j.expression.length > 0),
  };
});

await step("crons-run", async () => {
  await pb.crons.run("__pbDBOptimize__");
  return { ran: true };
});

await step("crons-run-unknown-404", async () => {
  try {
    await pb.crons.run("__nope__");
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 404 };
  }
});

await step("settings-roundtrip", async () => {
  const s = await pb.settings.getAll();
  const updated = await pb.settings.update({ meta: { appName: `m50app${TS}` } });
  return {
    hasMeta: typeof s?.meta === "object",
    nameApplied: updated?.meta?.appName === `m50app${TS}`,
  };
});

await step("backup-create", async () => {
  await pb.backups.create(BK);
  return { created: true };
});

await step("backup-list", async () => {
  const items = await pb.backups.getFullList();
  const mine = items.find((b) => b.key === BK);
  return {
    found: !!mine,
    hasSize: (mine?.size ?? 0) > 0,
    shape: items.length > 0 ? "key" in items[0] && "size" in items[0] && "modified" in items[0] : false,
  };
});

await step("backup-delete", async () => {
  await pb.backups.delete(BK);
  const items = await pb.backups.getFullList();
  return { gone: !items.some((b) => b.key === BK) };
});

await step("backups-forbidden-for-guests", async () => {
  const anon = new PocketBase(base);
  try {
    await anon.backups.getFullList();
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 401 || e?.status === 403 };
  }
});

console.log(JSON.stringify(out, null, 1));
process.exit(Object.values(out).some((v) => !v.ok) ? 1 : 0);
