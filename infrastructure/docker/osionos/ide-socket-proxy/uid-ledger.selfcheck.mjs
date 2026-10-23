// The ledger, the allocator and the init shape, driven through the same vetCreateBody the proxy
// runs, against a real ledger file in a temp dir. proxy.mjs --selfcheck calls ledgerFailures();
// the image does not ship this file's temp dir, only the file (verify.sh runs it there).
// Mutation proof (A1.2): delete the `includes(uid)` line in uid-ledger.mjs admit(); the case
// "new owner + a bound uid refused" must then fail with "got null".

import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { homeVolumeFor, shapeLimits } from "./create-shape.mjs";
import { OWNER, WORKSPACE, digestOf, mk } from "./create-shape.selfcheck.mjs";
import { createLedger } from "./uid-ledger.mjs";

const LIMITS = shapeLimits(process.env);
const OWNER_B = "33333333-3333-4333-8333-333333333333";
const OWNER_C = "44444444-4444-4444-8444-444444444444";
const boxPath = (owner, ws) => `/containers/create?name=ide-${digestOf(owner, ws)}`;
const initPath = (owner, ws) => `/containers/create?name=ideinit-${digestOf(owner, ws)}`;

function boxBody(owner, ws, uid) {
  const body = mk();
  body.User = `${uid}:10001`;
  body.Labels = { "osio.ide.managed": "1", "osio.ide.owner": owner, "osio.ide.workspace": ws, "osio.ide.uid": String(uid) };
  body.HostConfig.Mounts = [
    { ...body.HostConfig.Mounts[0], Source: `osio-ide-vol-${digestOf(owner, ws)}` },
    { ...body.HostConfig.Mounts[1], Source: homeVolumeFor(owner) },
  ];
  return body;
}

function initBody(owner, ws, uid) {
  return {
    Image: LIMITS.image,
    User: "0:0",
    Entrypoint: ["/usr/local/sbin/osio-volume-init"],
    Env: [`OSIO_UID=${uid}`],
    Labels: { "osio.ide.managed": "1", "osio.ide.owner": owner, "osio.ide.workspace": ws, "osio.ide.uid": String(uid) },
    HostConfig: {
      NetworkMode: "none", CapDrop: ["ALL"], CapAdd: ["CHOWN", "DAC_READ_SEARCH", "FOWNER"],
      SecurityOpt: ["no-new-privileges:true"], ReadonlyRootfs: true,
      Mounts: [
        { Type: "volume", Source: `osio-ide-vol-${digestOf(owner, ws)}`, Target: "/workspace" },
        { Type: "volume", Source: homeVolumeFor(owner), Target: "/home/coder" },
      ],
      PidsLimit: 16, Memory: 134217728, MemorySwap: 134217728, RestartPolicy: { Name: "no" },
    },
  };
}

const withHost = (body, patch) => ({ ...body, HostConfig: { ...body.HostConfig, ...patch } });

export async function ledgerFailures(vetCreateBody) {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
  const dir = await mkdtemp(path.join(tmpdir(), "ide-ledger-"));
  const logs = [];
  const fresh = (name) => createLedger({ file: path.join(dir, name), log: (line) => logs.push(line) });
  const lines = async (name) => (await readFile(path.join(dir, name), "utf8")).split("\n").filter(Boolean).length;
  try {
    const ledger = fresh("main.jsonl");
    const vetBox = (owner, ws, uid, l = ledger) => vetCreateBody(boxBody(owner, ws, uid), boxPath(owner, ws), l);
    const vetInit = (body, owner = OWNER, ws = WORKSPACE, l = ledger) => vetCreateBody(body, initPath(owner, ws), l);

    chk("unknown owner + fresh uid admitted", await vetBox(OWNER, WORKSPACE, 20000), null);
    chk("the same pair again admitted", await vetBox(OWNER, WORKSPACE, 20000), null);
    chk("missing ledger logged once", logs.filter((l) => l.includes("missing")).length, 1);
    chk("one binding on disk", await lines("main.jsonl"), 1);
    chk("same owner + new uid refused", await vetBox(OWNER, WORKSPACE, 20001), "uid-binding");
    chk("new owner + a bound uid refused", await vetBox(OWNER_B, WORKSPACE, 20000), "uid-binding");
    for (const uid of [10001, 19999, 60000, 65534]) chk(`uid ${uid} refused`, await vetBox(OWNER_C, WORKSPACE, uid), "User");
    const labelMismatch = boxBody(OWNER_C, WORKSPACE, 20005);
    labelMismatch.User = "20006:10001";
    chk("User differing from the uid label refused", await vetCreateBody(labelMismatch, boxPath(OWNER_C, WORKSPACE), ledger), "Labels");
    chk("gid other than 10001 refused", await vetCreateBody({ ...boxBody(OWNER_C, WORKSPACE, 20005), User: "20005:20005" }, boxPath(OWNER_C, WORKSPACE), ledger), "User");
    chk("non-numeric User refused", await vetCreateBody({ ...boxBody(OWNER_C, WORKSPACE, 20005), User: "coder:10001" }, boxPath(OWNER_C, WORKSPACE), ledger), "User");
    chk("refusals bound nothing", await lines("main.jsonl"), 1);
    chk("a box with CapAdd refused", await vetCreateBody(withHost(boxBody(OWNER_C, WORKSPACE, 20005), { CapAdd: ["CHOWN"] }), boxPath(OWNER_C, WORKSPACE), ledger), "HostConfig keys");
    chk("a second owner with a fresh uid admitted", await vetBox(OWNER_B, WORKSPACE, 20001), null);

    const restarted = fresh("main.jsonl");
    chk("bindings survive a restart (owner A, another uid)", await vetBox(OWNER, WORKSPACE, 20002, restarted), "uid-binding");
    chk("bindings survive a restart (bound pair)", await vetBox(OWNER, WORKSPACE, 20000, restarted), null);

    const owners = [OWNER, OWNER_B, OWNER_C, "55555555-5555-4555-8555-555555555555"];
    const allocator = fresh("alloc.jsonl");
    const got = await Promise.all(owners.map((owner) => allocator.allocate(owner)));
    chk("parallel allocations are distinct", new Set(got).size, owners.length);
    chk("allocation starts at 20000", Math.min(...got), 20000);
    chk("the same owner gets the same uid", await allocator.allocate(OWNER_B), got[1]);
    chk("an allocated binding is enforced on a create", await vetBox(OWNER_B, WORKSPACE, got[1] + 1, allocator), "uid-binding");
    chk("an allocated binding admits its own create", await vetBox(OWNER_B, WORKSPACE, got[1], allocator), null);

    await writeFile(path.join(dir, "full.jsonl"), `${JSON.stringify({ owner: OWNER_B, uid: 59999 })}\n`);
    const full = fresh("full.jsonl");
    const exhausted = await full.allocate(OWNER_C).then(() => "allocated", (error) => error.reason);
    chk("an exhausted range refuses a new owner", exhausted, "exhausted");
    chk("an exhausted range still serves a bound owner", await full.allocate(OWNER_B), 59999);

    await writeFile(path.join(dir, "corrupt.jsonl"), `${JSON.stringify({ owner: OWNER, uid: 20000 })}\nnot json\n`);
    chk("corrupt ledger refuses every create", await vetBox(OWNER, WORKSPACE, 20000, fresh("corrupt.jsonl")), "ledger");
    await writeFile(path.join(dir, "dup.jsonl"), `${JSON.stringify({ owner: OWNER, uid: 20000 })}\n${JSON.stringify({ owner: OWNER_B, uid: 20000 })}\n`);
    chk("a uid bound twice is corrupt", await vetBox(OWNER, WORKSPACE, 20000, fresh("dup.jsonl")), "ledger");
    await mkdir(path.join(dir, "unreadable.jsonl"));
    chk("unreadable ledger refuses every create", await vetBox(OWNER, WORKSPACE, 20000, fresh("unreadable.jsonl")), "ledger");
    const refusedAlloc = await fresh("unreadable.jsonl").allocate(OWNER).then(() => "allocated", (error) => error.reason);
    chk("unreadable ledger refuses an allocation", refusedAlloc, "ledger");
    const unwritable = createLedger({ file: path.join(dir, "no-such-dir", "x.jsonl"), log: () => {} });
    chk("a failed write binds nothing and refuses", await vetBox(OWNER, WORKSPACE, 20000, unwritable), "ledger");

    const init = fresh("init.jsonl");
    chk("init canonical admitted", await vetInit(initBody(OWNER, WORKSPACE, 20000), OWNER, WORKSPACE, init), null);
    chk("init bound the uid for the box", await vetBox(OWNER, WORKSPACE, 20001, init), "uid-binding");
    const INIT_REFUSALS = [
      ["with DAC_OVERRIDE", withHost(initBody(OWNER, WORKSPACE, 20000), { CapAdd: ["CHOWN", "DAC_READ_SEARCH", "FOWNER", "DAC_OVERRIDE"] }), "CapAdd"],
      ["without DAC_READ_SEARCH", withHost(initBody(OWNER, WORKSPACE, 20000), { CapAdd: ["CHOWN", "FOWNER"] }), "CapAdd"],
      ["with a network", withHost(initBody(OWNER, WORKSPACE, 20000), { NetworkMode: "osio-ide-sandbox-net" }), "NetworkMode"],
      ["with a foreign home", withHost(initBody(OWNER, WORKSPACE, 20000), { Mounts: [initBody(OWNER, WORKSPACE, 20000).HostConfig.Mounts[0], { Type: "volume", Source: homeVolumeFor(OWNER_B), Target: "/home/coder" }] }), "Mounts"],
      ["with a Cmd", { ...initBody(OWNER, WORKSPACE, 20000), Cmd: ["sh"] }, "Cmd"],
      ["with NoCopy", withHost(initBody(OWNER, WORKSPACE, 20000), { Mounts: initBody(OWNER, WORKSPACE, 20000).HostConfig.Mounts.map((m) => ({ ...m, VolumeOptions: { NoCopy: true } })) }), "Mounts"],
      ["with the box's entrypoint", { ...initBody(OWNER, WORKSPACE, 20000), Entrypoint: ["/usr/local/sbin/box-init"] }, "Entrypoint"],
      ["without an Entrypoint", (() => { const b = initBody(OWNER, WORKSPACE, 20000); delete b.Entrypoint; return b; })(), "top-level keys"],
      ["as a user other than root", { ...initBody(OWNER, WORKSPACE, 20000), User: "20000:10001" }, "User"],
      ["with a read-write rootfs", withHost(initBody(OWNER, WORKSPACE, 20000), { ReadonlyRootfs: false }), "ReadonlyRootfs"],
      ["with 17 pids", withHost(initBody(OWNER, WORKSPACE, 20000), { PidsLimit: 17 }), "PidsLimit"],
      ["with 129 MiB", withHost(initBody(OWNER, WORKSPACE, 20000), { Memory: 135266304, MemorySwap: 135266304 }), "Memory"],
      ["with swap", withHost(initBody(OWNER, WORKSPACE, 20000), { MemorySwap: 268435456 }), "MemorySwap"],
      ["with a tmpfs", withHost(initBody(OWNER, WORKSPACE, 20000), { Tmpfs: { "/tmp": "size=1m" } }), "HostConfig keys"],
      ["with a second Env entry", { ...initBody(OWNER, WORKSPACE, 20000), Env: ["OSIO_UID=20000", "X=1"] }, "Env"],
      ["with an Env uid that differs from the label", { ...initBody(OWNER, WORKSPACE, 20000), Env: ["OSIO_UID=20001"] }, "Labels"],
      ["with uid 10001", { ...initBody(OWNER, WORKSPACE, 20000), Env: ["OSIO_UID=10001"] }, "Env"],
      ["with a foreign image", { ...initBody(OWNER, WORKSPACE, 20000), Image: "alpine" }, "Image"],
    ];
    for (const [label, body, want] of INIT_REFUSALS) chk(`init ${label} refused`, await vetInit(body, OWNER, WORKSPACE, fresh("init2.jsonl")), want);
    chk("init with another owner's digest refused", await vetCreateBody(initBody(OWNER, WORKSPACE, 20000), initPath(OWNER_B, WORKSPACE), fresh("init3.jsonl")), "name");
    chk("init bound a bound uid to another owner: refused", await vetInit(initBody(OWNER_B, WORKSPACE, 20000), OWNER_B, WORKSPACE, init), "uid-binding");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  return fail;
}
