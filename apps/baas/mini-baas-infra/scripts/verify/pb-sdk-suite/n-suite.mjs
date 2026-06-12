// m52 parity suite — Phase N surfaces through the OFFICIAL PocketBase SDK:
// view collections (create/list/sort/read-only), S3 file storage (settings →
// upload → serve → delete) against a shared MinIO, gif thumbnails.
// Usage: node n-suite.mjs <base> <suEmail> <suPass> <s3endpoint> <s3bucket>

import PocketBase from "pocketbase";

const [base, suEmail, suPass, s3endpoint, s3bucket] = process.argv.slice(2);
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
const SRC = `m52src${TS}`;
const VIEW = `m52view${TS}`;
const FCOL = `m52files${TS}`;

await step("setup", async () => {
  await pb.collection("_superusers").authWithPassword(suEmail, suPass);
  await pb.collections.create({
    name: SRC,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "n", type: "number" },
    ],
    listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
  });
  for (const [t, n] of [["alpha", 3], ["beta", 1], ["gamma", 2]]) {
    await pb.collection(SRC).create({ title: t, n });
  }
  return { ok: true };
});

await step("view-create", async () => {
  const c = await pb.collections.create({
    name: VIEW,
    type: "view",
    viewQuery: `SELECT id, title, n FROM ${SRC}`,
    listRule: "",
  });
  return { type: c.type, named: c.name === VIEW };
});

await step("view-list-sorted", async () => {
  const res = await pb.collection(VIEW).getList(1, 10, { sort: "-n" });
  return {
    titles: res.items.map((i) => i.title),
    ns: res.items.map((i) => i.n),
    totalItems: res.totalItems,
  };
});

await step("view-filter-and-sort", async () => {
  const res = await pb.collection(VIEW).getList(1, 10, { filter: "n > 1", sort: "-n" });
  return { titles: res.items.map((i) => i.title), totalItems: res.totalItems };
});

await step("view-create-rejected", async () => {
  try {
    await pb.collection(VIEW).create({ title: "nope" });
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

await step("view-delete", async () => {
  await pb.collections.delete(VIEW);
  return { deleted: true };
});

await step("s3-enable", async () => {
  const s = await pb.settings.update({
    s3: {
      enabled: true,
      bucket: s3bucket,
      region: "us-east-1",
      endpoint: s3endpoint,
      accessKey: "minioadmin",
      secret: "minioadmin",
      forcePathStyle: true,
    },
  });
  return { enabled: s?.s3?.enabled === true };
});

let fileRec = null;
let fileUrl = "";
await step("s3-upload-and-serve", async () => {
  await pb.collections.create({
    name: FCOL,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "doc", type: "file", maxSelect: 1 },
    ],
    listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
  });
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAJElEQVR4nGP8z4APMOGV" +
    "HZUelR6VHpUelR6VHpUelaZUGgAcwwIkSdvNNQAAAABJRU5ErkJggg==", "base64");
  fileRec = await pb.collection(FCOL).create({
    title: "s3file",
    doc: new File([png], "cloud.png", { type: "image/png" }),
  });
  fileUrl = pb.files.getURL(fileRec, fileRec.doc);
  const resp = await fetch(fileUrl);
  const bytes = new Uint8Array(await resp.arrayBuffer());
  return { status: resp.status, isPng: bytes[1] === 0x50, sized: bytes.length > 100 };
});

await step("s3-gone-after-delete", async () => {
  await pb.collection(FCOL).delete(fileRec.id);
  const resp = await fetch(fileUrl);
  return { status: resp.status };
});

await step("gif-thumb", async () => {
  // 1x1 gif
  const gif = Buffer.from("R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==", "base64");
  const r = await pb.collection(FCOL).create({
    title: "gif",
    doc: new File([gif], "dot.gif", { type: "image/gif" }),
  });
  const url = pb.files.getURL(r, r.doc) + "?thumb=8x8";
  const resp = await fetch(url);
  const bytes = new Uint8Array(await resp.arrayBuffer());
  return { status: resp.status, served: bytes.length > 0 };
});

await step("cleanup", async () => {
  await pb.settings.update({ s3: { enabled: false } });
  await pb.collections.delete(FCOL);
  await pb.collections.delete(SRC);
  return { done: true };
});

console.log(JSON.stringify(out, null, 1));
process.exit(Object.values(out).some((v) => !v.ok) ? 1 : 0);
