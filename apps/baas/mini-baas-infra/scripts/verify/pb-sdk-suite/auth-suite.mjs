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
    otp: { enabled: true, duration: 300, length: 8 },
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

await step("request-otp-shape", async () => {
  // enumeration-safe: an otpId comes back whether or not the email exists
  const known = await alice.collection(USERS).requestOTP("alice@m49.dev");
  const unknown = await alice.collection(USERS).requestOTP("ghost@m49.dev");
  return { knownHasId: typeof known.otpId === "string" && known.otpId.length > 5,
           unknownHasId: typeof unknown.otpId === "string" && unknown.otpId.length > 5 };
});

await step("auth-with-otp-wrong-code", async () => {
  const { otpId } = await alice.collection(USERS).requestOTP("alice@m49.dev");
  try {
    await alice.collection(USERS).authWithOTP(otpId, "00000000");
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

await step("request-verification-204", async () => {
  const ok = await alice.collection(USERS).requestVerification("alice@m49.dev");
  const ghost = await alice.collection(USERS).requestVerification("ghost@m49.dev");
  return { ok, ghost };
});

await step("confirm-verification-garbage-400", async () => {
  try {
    await alice.collection(USERS).confirmVerification("not-a-real-token");
    return { rejected: false };
  } catch (e) {
    return { rejected: e?.status === 400 };
  }
});

await step("request-password-reset-204", async () => {
  const ok = await alice.collection(USERS).requestPasswordReset("alice@m49.dev");
  return { ok };
});

await step("request-email-change-requires-auth", async () => {
  const anon = new PocketBase(base);
  try {
    await anon.collection(USERS).requestEmailChange("new@m49.dev");
    return { blocked: false };
  } catch (e) {
    return { blocked: e?.status === 401 };
  }
});

await step("mfa-first-factor-401-with-mfaId", async () => {
  await su.collections.update(USERS, { mfa: { enabled: true, duration: 300 } });
  const fresh = new PocketBase(base);
  let got = null;
  try {
    await fresh.collection(USERS).authWithPassword("alice@m49.dev", "alice-pass-123");
  } catch (e) {
    got = e?.response?.mfaId ?? null;
  }
  await su.collections.update(USERS, { mfa: { enabled: false } });
  return { mfaIdIssued: typeof got === "string" && got.length > 5 };
});

const IMP = `m49import${TS}`;
await step("collections-import", async () => {
  await su.collections.import([
    {
      name: IMP,
      type: "base",
      fields: [{ name: "x", type: "text" }],
      listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
    },
  ]);
  const c = await su.collections.getOne(IMP);
  await su.collections.delete(IMP);
  return { imported: c?.name === IMP };
});

// ── rules matrix: advanced constructs (:modifiers, multi-value, geoDistance) ──
const RM = `m49rules${TS}`;
await step("rules-matrix-collection", async () => {
  await su.collections.create({
    name: RM,
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "tags", type: "select", maxSelect: 5, values: ["a", "b", "c", "x", "y"] },
      { name: "place", type: "geoPoint" },
    ],
    // list rule exercises a :modifier; records visible only with >=2 tags
    listRule: "tags:length >= 2",
    viewRule: "",
    createRule: "",
    updateRule: "",
    deleteRule: "",
  });
  // seed: one with 1 tag (hidden), two with >=2 tags (visible)
  await su.collection(RM).create({ title: "one", tags: ["a"], place: { lon: 2.35, lat: 48.85 } });
  await su.collection(RM).create({ title: "two", tags: ["a", "b"], place: { lon: 2.35, lat: 48.85 } });
  await su.collection(RM).create({ title: "three", tags: ["a", "b", "c"], place: { lon: -0.12, lat: 51.5 } });
  return { ok: true };
});

await step("rule-modifier-length-filters-list", async () => {
  // an anonymous client sees only records the :length list rule admits
  const anon = new PocketBase(base);
  const res = await anon.collection(RM).getList(1, 50, { sort: "title" });
  return { titles: res.items.map((i) => i.title), totalItems: res.totalItems };
});

await step("filter-each-anyof", async () => {
  // PB multi-value idiom: :each ?= matches records where ANY element equals
  const any = await su.collection(RM).getList(1, 50, { filter: "tags:each ?= 'c'", sort: "title" });
  // :each = matches records where ALL elements equal (none here)
  const all = await su.collection(RM).getList(1, 50, { filter: "tags:each = 'c'", sort: "title" });
  return { anyTitles: any.items.map((i) => i.title), allTitles: all.items.map((i) => i.title) };
});

await step("filter-modifier-length", async () => {
  const res = await su.collection(RM).getList(1, 50, { filter: "tags:length = 3", sort: "title" });
  return { titles: res.items.map((i) => i.title) };
});

await step("filter-geodistance", async () => {
  // within ~50km of Paris → the two Paris records
  const res = await su.collection(RM).getList(1, 50, {
    filter: "geoDistance(place.lon, place.lat, 2.35, 48.85) < 50",
    sort: "title",
  });
  return { titles: res.items.map((i) => i.title) };
});

// @request.body.* in a create rule: the submitted owner must equal auth.id
const RB = `m49reqbody${TS}`;
await step("request-body-rule", async () => {
  await su.collections.create({
    name: RB, type: "base",
    fields: [{ name: "title", type: "text" }, { name: "owner", type: "text" }],
    listRule: "", viewRule: "",
    createRule: "@request.body.owner = @request.auth.id",
    updateRule: "", deleteRule: "",
  });
  // alice may create a record whose body owner is her own id
  const okRec = await alice.collection(RB).create({ title: "mine", owner: aliceId }).then(() => true).catch(() => false);
  // ...but not one owned by bob
  let forged = false;
  try { await alice.collection(RB).create({ title: "forged", owner: bobId }); forged = true; }
  catch (e) { forged = e?.status === 400 ? false : "err" + e?.status; }
  await su.collections.delete(RB);
  return { ownCreateAllowed: okRec, foreignBodyRejected: forged === false };
});

// @collection.* join (membership pattern): a doc is visible only if the
// caller has a membership row for it.
const DOCS = `m49docs${TS}`;
const MEM = `m49mem${TS}`;
await step("collection-join-setup", async () => {
  // MEM must exist before DOCS references it (PB validates @collection refs)
  await su.collections.create({
    name: MEM, type: "base",
    fields: [{ name: "doc", type: "text" }, { name: "user", type: "text" }],
    listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "",
  });
  await su.collections.create({
    name: DOCS, type: "base",
    fields: [{ name: "title", type: "text" }],
    listRule: `@collection.${MEM}.doc ?= id && @collection.${MEM}.user ?= @request.auth.id`,
    viewRule: `@collection.${MEM}.doc ?= id && @collection.${MEM}.user ?= @request.auth.id`,
    createRule: "", updateRule: "", deleteRule: "",
  });
  const d1 = await su.collection(DOCS).create({ title: "doc-alice" });
  const d2 = await su.collection(DOCS).create({ title: "doc-bob" });
  await su.collection(MEM).create({ doc: d1.id, user: aliceId });
  await su.collection(MEM).create({ doc: d2.id, user: bobId });
  return { ok: true };
});

await step("collection-join-isolation", async () => {
  const a = await alice.collection(DOCS).getList(1, 50, { sort: "title" });
  const b = await bob.collection(DOCS).getList(1, 50, { sort: "title" });
  return {
    aliceSees: a.items.map((i) => i.title),
    bobSees: b.items.map((i) => i.title),
  };
});

await step("collection-join-cleanup", async () => {
  await su.collections.delete(DOCS);
  await su.collections.delete(MEM);
  return { ok: true };
});

await step("rules-matrix-cleanup", async () => {
  await su.collections.delete(RM);
  return { ok: true };
});

await step("cleanup", async () => {
  await su.collections.delete(POSTS);
  await su.collections.delete(USERS);
  return { done: true };
});

console.log(JSON.stringify(out, null, 1));
process.exit(Object.values(out).some((v) => !v.ok) ? 1 : 0);
