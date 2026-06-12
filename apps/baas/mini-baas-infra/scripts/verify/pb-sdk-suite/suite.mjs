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
import { EventSource } from "eventsource";
// Node has no global EventSource; the official SDK expects one for realtime.
globalThis.EventSource = EventSource;

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

const AUTHORS = `m48authors${Date.now() % 100000}`;
let authorsId = "";
let authorId = "";
await step("expand-setup", async () => {
  const a = await pb.collections.create({
    name: AUTHORS,
    type: "base",
    fields: [{ name: "name", type: "text" }],
    listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
  });
  authorsId = a.id;
  await pb.collections.update(COL, {
    fields: [
      { name: "title", type: "text" },
      { name: "views", type: "number" },
      { name: "done", type: "bool" },
      { name: "meta", type: "json" },
      { name: "author", type: "relation", collectionId: authorsId, maxSelect: 1 },
    ],
  });
  const author = await pb.collection(AUTHORS).create({ name: "ada" });
  authorId = author.id;
  await pb.collection(COL).create({ title: "with-author", views: 1, done: false, author: authorId });
  return { ok: true };
});

await step("expand-forward", async () => {
  const res = await pb.collection(COL).getList(1, 50, {
    filter: "title = 'with-author'",
    expand: "author",
  });
  const item = res.items[0];
  return {
    found: !!item,
    expandedName: item?.expand?.author?.name,
    rawIdKept: typeof item?.author === "string" && item.author.length === 15,
  };
});

await step("expand-back-relation", async () => {
  const res = await pb.collection(AUTHORS).getList(1, 10, {
    expand: `${COL}_via_author`,
  });
  const ada = res.items.find((a) => a.name === "ada");
  const back = ada?.expand?.[`${COL}_via_author`];
  return {
    isArray: Array.isArray(back),
    titles: Array.isArray(back) ? back.map((p) => p.title) : null,
  };
});

await step("expand-cleanup", async () => {
  await pb.collections.delete(AUTHORS).catch(() => {});
  return { ok: true };
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

await step("realtime-create-event", async () => {
  // subscribe, mutate, await the event — the SSE protocol end to end
  const got = new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("no realtime event within 8s")), 8000);
    pb.collection(COL)
      .subscribe("*", (e) => {
        clearTimeout(t);
        resolve(e);
      })
      .catch(reject);
  });
  // give the subscription a moment to register
  await new Promise((r) => setTimeout(r, 600));
  await pb.collection(COL).create({ title: "rt-target", views: 1, done: false });
  const e = await got;
  await pb.collection(COL).unsubscribe("*");
  return { action: e.action, title: e.record?.title, hasId: ID15.test(e.record?.id ?? "") };
});

await step("batch-disabled-by-default", async () => {
  const b = pb.createBatch();
  b.collection(COL).create({ title: "nope", views: 0, done: false });
  try {
    await b.send();
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 403 };
  }
});

await step("enable-batch", async () => {
  const s = await pb.settings.update({ batch: { enabled: true, maxRequests: 50, timeout: 3 } });
  return { batchEnabled: s?.batch?.enabled === true };
});

await step("batch-atomic-create", async () => {
  const b = pb.createBatch();
  b.collection(COL).create({ title: "batch-1", views: 11, done: false });
  b.collection(COL).create({ title: "batch-2", views: 12, done: true });
  const res = await b.send();
  return {
    statuses: res.map((r) => r.status),
    titles: res.map((r) => r.body?.title),
    idsOk: res.every((r) => ID15.test(r.body?.id ?? "")),
  };
});

const FCOL = `m48files${Date.now() % 100000}`;
let fileRecId = "";
let fileUrl = "";
await step("file-collection-create", async () => {
  const c = await pb.collections.create({
    name: FCOL,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "doc", type: "file", maxSelect: 1 },
    ],
    listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
  });
  return { named: c.name === FCOL };
});

await step("file-upload-multipart", async () => {
  // ~600-byte deterministic png
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAJElEQVR4nGP8z4APMOGV" +
    "HZUelR6VHpUelR6VHpUelaZUGgAcwwIkSdvNNQAAAABJRU5ErkJggg==", "base64");
  const r = await pb.collection(FCOL).create({
    title: "with-file",
    doc: new File([png], "pic one.PNG", { type: "image/png" }),
  });
  fileRecId = r.id;
  return {
    titled: r.title === "with-file",
    storedNameShape: /^pic_one_[a-zA-Z0-9]{10}\.png$/i.test(r.doc),
  };
});

await step("file-serve", async () => {
  const r = await pb.collection(FCOL).getOne(fileRecId);
  fileUrl = pb.files.getURL(r, r.doc);
  const resp = await fetch(fileUrl);
  const bytes = new Uint8Array(await resp.arrayBuffer());
  return { status: resp.status, isPng: bytes[1] === 0x50 && bytes[2] === 0x4e, sizeOk: bytes.length > 100 };
});

await step("file-thumb", async () => {
  const resp = await fetch(`${fileUrl}?thumb=16x16`);
  const bytes = new Uint8Array(await resp.arrayBuffer());
  return { status: resp.status, isPng: bytes[1] === 0x50, smaller: bytes.length > 0 };
});

await step("file-gone-after-record-delete", async () => {
  await pb.collection(FCOL).delete(fileRecId);
  const resp = await fetch(fileUrl);
  return { status: resp.status };
});

await step("file-collection-delete", async () => {
  await pb.collections.delete(FCOL);
  return { deleted: true };
});

await step("collection-delete", async () => {
  await pb.collections.delete(COL);
  return { deleted: true };
});

console.log(JSON.stringify(out, null, 1));
const failed = Object.entries(out).filter(([, v]) => !v.ok);
process.exit(failed.length > 0 ? 1 : 0);
