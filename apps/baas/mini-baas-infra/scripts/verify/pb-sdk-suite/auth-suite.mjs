// m49 parity suite — auth collections + API rules through the OFFICIAL
// PocketBase JS SDK, against binocle-one AND real PB; normalized outcomes
// diffed by the m49 gate. Covers: registration, authWithPassword,
// authRefresh, owner-based rules isolation (two users), guest behavior,
// impersonation, secret hygiene (password never serialized).

import PocketBase from "pocketbase";

const [base, suEmail, suPass] = process.argv.slice(2);
const su = new PocketBase(base);
su.autoCancellation(false);
const out = {};
const ID15 = /^[a-z0-9]{15}$/;

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
const USERS = `m49users${TS}`;
const POSTS = `m49posts${TS}`;

await step("setup-superuser", async () => {
  await su.collection("_superusers").authWithPassword(suEmail, suPass);
  return { ok: true };
});

await step("auth-collection-create", async () => {
  const c = await su.collections.create({
    name: USERS,
    type: "auth",
    fields: [{ name: "nick", type: "text" }],
    createRule: "", // public registration
    listRule: null,
    viewRule: null,
    updateRule: null,
    deleteRule: null,
  });
  return { type: c.type, named: c.name === USERS };
});

await step("rules-collection-create", async () => {
  const c = await su.collections.create({
    name: POSTS,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "owner", type: "text" },
    ],
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: "owner = @request.auth.id",
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",
  });
  return { named: c.name === POSTS };
});

const alice = new PocketBase(base);
alice.autoCancellation(false);
const bob = new PocketBase(base);
bob.autoCancellation(false);

await step("register-alice", async () => {
  const r = await alice.collection(USERS).create({
    email: "alice@m49.dev",
    password: "alice-pass-123",
    passwordConfirm: "alice-pass-123",
    nick: "al",
  });
  return {
    idOk: ID15.test(r.id),
    nick: r.nick,
    passwordHidden: !("password" in r) && !("passwordConfirm" in r),
  };
});

await step("password-mismatch-rejected", async () => {
  try {
    await alice.collection(USERS).create({
      email: "x@m49.dev",
      password: "some-pass-123",
      passwordConfirm: "different-456",
    });
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

let aliceId = "";
await step("auth-with-password", async () => {
  const a = await alice.collection(USERS).authWithPassword("alice@m49.dev", "alice-pass-123");
  aliceId = a.record.id;
  return {
    hasToken: a.token.length > 20,
    emailVisible: a.record.email === "alice@m49.dev",
    passwordHidden: !("password" in a.record),
    nick: a.record.nick,
  };
});

await step("wrong-password-rejected", async () => {
  const fresh = new PocketBase(base);
  try {
    await fresh.collection(USERS).authWithPassword("alice@m49.dev", "WRONG-pass-1");
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

await step("auth-refresh", async () => {
  const before = alice.authStore.token;
  const a = await alice.collection(USERS).authRefresh();
  return { rotated: typeof a.token === "string" && a.token.length > 20, sameUser: a.record.id === aliceId };
});

let bobId = "";
await step("register-and-auth-bob", async () => {
  await bob.collection(USERS).create({
    email: "bob@m49.dev",
    password: "bob-pass-1234",
    passwordConfirm: "bob-pass-1234",
  });
  const a = await bob.collection(USERS).authWithPassword("bob@m49.dev", "bob-pass-1234");
  bobId = a.record.id;
  return { ok: ID15.test(bobId) };
});

let alicePost = "";
await step("create-own-post", async () => {
  const r = await alice.collection(POSTS).create({ title: "alice-1", owner: aliceId });
  alicePost = r.id;
  await bob.collection(POSTS).create({ title: "bob-1", owner: bobId });
  return { title: r.title };
});

await step("create-foreign-owner-rejected", async () => {
  try {
    await alice.collection(POSTS).create({ title: "forged", owner: bobId });
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

await step("owner-isolation-on-list", async () => {
  const a = await alice.collection(POSTS).getList(1, 10);
  const b = await bob.collection(POSTS).getList(1, 10);
  return {
    aliceSees: a.items.map((i) => i.title),
    bobSees: b.items.map((i) => i.title),
    totals: [a.totalItems, b.totalItems],
  };
});

await step("guest-list-is-empty", async () => {
  const anon = new PocketBase(base);
  const res = await anon.collection(POSTS).getList(1, 10);
  return { totalItems: res.totalItems, count: res.items.length };
});

await step("foreign-update-404", async () => {
  try {
    await bob.collection(POSTS).update(alicePost, { title: "hijack" });
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 404 };
  }
});

await step("foreign-view-404", async () => {
  try {
    await bob.collection(POSTS).getOne(alicePost);
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 404 };
  }
});

await step("own-update-and-delete", async () => {
  const r = await alice.collection(POSTS).update(alicePost, { title: "alice-1b" });
  await alice.collection(POSTS).delete(alicePost);
  return { updated: r.title === "alice-1b", deletedListed: (await alice.collection(POSTS).getList(1, 10)).totalItems };
});

await step("impersonate", async () => {
  const client = await su.collection(USERS).impersonate(bobId, 3600);
  const list = await client.collection(POSTS).getList(1, 10);
  return { actsAsBob: list.items.every((i) => i.owner === bobId), count: list.items.length };
});

await step("cleanup", async () => {
  await su.collections.delete(POSTS);
  await su.collections.delete(USERS);
  return { done: true };
});

console.log(JSON.stringify(out, null, 1));
process.exit(Object.values(out).some((v) => !v.ok) ? 1 : 0);
