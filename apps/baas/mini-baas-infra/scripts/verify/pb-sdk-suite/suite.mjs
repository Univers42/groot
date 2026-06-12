// m48 parity suite — drives the OFFICIAL PocketBase JS SDK against a target
// (binocle-one or real PocketBase) and emits a normalized outcome map on
// stdout. The m48 gate runs it against BOTH and diffs the maps: equal maps =
// the SDK cannot tell us apart on this surface.
//
// Usage: node suite.mjs <baseUrl> <superuserEmail> <superuserPassword>
//
// Normalization strips volatile values (ids, timestamps, tokens) and keeps
// structure: field presence, types, status codes, counts, ordering.

import PocketBase from "pocketbase";

const [base, suEmail, suPass] = process.argv.slice(2);
if (!base || !suEmail || !suPass) {
  console.error("usage: node suite.mjs <baseUrl> <email> <password>");
  process.exit(2);
}

const pb = new PocketBase(base);
pb.autoCancellation(false);
const out = {};
const ID15 = /^[a-z0-9]{15}$/;
const DT = /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}/;

function normRecord(r) {
  // keep structure, normalize volatility
  const o = {};
  for (const [k, v] of Object.entries(r)) {
    if (k === "id") o[k] = ID15.test(v) ? "<id15>" : `<odd:${v}>`;
    else if (k === "created" || k === "updated") o[k] = DT.test(v) ? "<dt>" : `<odd:${v}>`;
    else if (k === "collectionId") o[k] = "<cid>";
    else if (k === "collectionName") o[k] = "<col>";
    else o[k] = v;
  }
  return o;
}

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

const COL = `m48posts${Date.now() % 100000}`;

await step("health", async () => {
  const h = await pb.health.check();
  return { code: h.code ?? 200 };
});

await step("superuser-auth", async () => {
  const a = await pb.collection("_superusers").authWithPassword(suEmail, suPass);
  return { hasToken: typeof a.token === "string" && a.token.length > 20 };
});

await step("collection-create", async () => {
  const c = await pb.collections.create({
    name: COL,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "views", type: "number" },
      { name: "done", type: "bool" },
      { name: "meta", type: "json" },
    ],
    listRule: "",
    viewRule: "",
    createRule: "",
    updateRule: "",
    deleteRule: "",
  });
  return { named: c.name === COL, type: c.type, hasFields: Array.isArray(c.fields) && c.fields.length >= 4 };
});

let rid = "";
await step("record-create", async () => {
  const r = await pb.collection(COL).create({
    title: "alpha",
    views: 5,
    done: true,
    meta: { a: 1 },
  });
  rid = r.id;
  return normRecord(r);
});

await step("record-create-more", async () => {
  await pb.collection(COL).create({ title: "beta", views: 2, done: false });
  await pb.collection(COL).create({ title: "gamma", views: 9, done: false });
  const r = await pb.collection(COL).create({ title: "albatross", views: 7, done: true });
  return normRecord(r);
});

await step("record-view", async () => normRecord(await pb.collection(COL).getOne(rid)));

await step("record-update", async () => {
  const r = await pb.collection(COL).update(rid, { views: 6 });
  return { views: r.views, title: r.title };
});

await step("list-filter-sort", async () => {
  const res = await pb.collection(COL).getList(1, 2, {
    filter: "views > 1 && title ~ 'a'",
    sort: "-views,title",
  });
  return {
    page: res.page,
    perPage: res.perPage,
    totalItems: res.totalItems,
    totalPages: res.totalPages,
    titles: res.items.map((i) => i.title),
  };
});

await step("list-page2", async () => {
  const res = await pb.collection(COL).getList(2, 2, {
    filter: "views > 1 && title ~ 'a'",
    sort: "-views,title",
  });
  return { page: res.page, titles: res.items.map((i) => i.title) };
});

await step("full-list-skiptotal", async () => {
  const items = await pb.collection(COL).getFullList({ sort: "title" });
  return { count: items.length, titles: items.map((i) => i.title) };
});

await step("first-match", async () => {
  const r = await pb.collection(COL).getFirstListItem("title = 'beta'");
  return { title: r.title, views: r.views, done: r.done };
});

await step("typed-values", async () => {
  const r = await pb.collection(COL).getFirstListItem("title = 'alpha'");
  return {
    metaIsObject: typeof r.meta === "object" && r.meta?.a === 1,
    doneIsBool: typeof r.done === "boolean",
    viewsIsNumber: typeof r.views === "number",
  };
});

await step("record-delete", async () => {
  await pb.collection(COL).delete(rid);
  try {
    await pb.collection(COL).getOne(rid);
    return { goneAfterDelete: false };
  } catch (e) {
    return { goneAfterDelete: e?.status === 404 };
  }
});

await step("guest-forbidden-on-locked", async () => {
  // a fresh client with NO auth must not manage collections
  const anon = new PocketBase(base);
  try {
    await anon.collections.create({ name: `x${Date.now() % 1000}`, type: "base", fields: [] });
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 401 || e?.status === 403 };
  }
});

await step("collection-delete", async () => {
  await pb.collections.delete(COL);
  return { deleted: true };
});

console.log(JSON.stringify(out, null, 1));
const failed = Object.entries(out).filter(([, v]) => !v.ok);
process.exit(failed.length > 0 ? 1 : 0);
