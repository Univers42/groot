import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";

// The runtime half of the <graph-studio> contract: the pinned pack, in Chromium, does what the
// static contract (tests/graph-studio-contract/contract.json) says. Every expectation that can be
// is read from that file, so the two halves cannot disagree. No sleeps: each wait is the element's
// own promise or event, bounded by WAIT_MS.
//
// The host does what osionos's host will (PLAN §5, D9): read the base from
// <meta name="graph-studio-base">, import base + graph-studio.js, defineGraphStudio(), await the
// upgrade, and set `wasm` to an absolute base URL before the element is connected.

interface Leaf<T> {
  value: T;
  at: string;
}
interface Contract {
  source_rev: string;
  element: { tag: Leaf<string>; entry_exports: Leaf<string>[] };
  versions: { host_api: Leaf<number>; open_vias: Leaf<string[]> };
  host_members: Record<string, Leaf<string>>;
  events: { detail: Record<string, Leaf<string>>; init: Leaf<{ bubbles: boolean; composed: boolean }> };
  rejection: { load_graph_rejection_name: Leaf<string> };
  ingest: {
    refusal_message: Leaf<string>;
    refuse_duplicate_node_id: Leaf<string>;
    refuse_dangling_endpoint: Leaf<string>;
  };
}

const CONTRACT: Contract = JSON.parse(
  readFileSync(new URL("../../graph-studio-contract/contract.json", import.meta.url), "utf8"),
);
const TAG = CONTRACT.element.tag.value;
const EVENTS = Object.keys(CONTRACT.events.detail);
const WAIT_MS = 15_000;

/** A message template from the source (`${...}` holes) as a regex: each hole matches anything. */
function templateRegex(template: string): RegExp {
  const parts = template.split(/\$\{[^}]*\}/).map((p) => p.replace(/[.*+?^$()|[\]\\{}]/g, "\\$&"));
  return new RegExp(`^${parts.join(".+")}$`);
}

/** What a refusal's message must look like: the class's `${source}: ${message}` around the template. */
function refusalRegex(template: string): RegExp {
  const outer = CONTRACT.ingest.refusal_message.value.replace(/^`|`$/g, "");
  const inner = templateRegex(template).source.slice(1, -1);
  return new RegExp(`^${templateRegex(outer).source.slice(1, -1).replace(/\.\+$/, inner)}$`);
}

interface Recorded {
  type: string;
  detail: unknown;
  bubbles: boolean;
  composed: boolean;
}

/**
 * Loads the pack the way the host will and connects one element. `wasm: false` leaves the attribute
 * unset (the negative control for D9). Events are recorded from `document`, so each one seen there
 * also proves `bubbles` and `composed` crossed the shadow root.
 */
async function mount(page: Page, opts: { wasm: boolean }) {
  await page.goto("/");
  return page.evaluate(
    async ({ tag, events, wasm }) => {
      const base = document.querySelector<HTMLMetaElement>('meta[name="graph-studio-base"]')?.content;
      if (!base) throw new Error("no graph-studio-base meta");
      const mod = await import(new URL(`${base}graph-studio.js`, location.href).href);
      const w = window as unknown as { __events: Recorded[]; __el: HTMLElement };
      w.__events = [];
      for (const name of events) {
        document.addEventListener(name, (e) => {
          const ce = e as CustomEvent;
          w.__events.push({ type: ce.type, detail: ce.detail, bubbles: ce.bubbles, composed: ce.composed });
        });
      }
      const definedBefore = customElements.get(tag) !== undefined;
      mod.defineGraphStudio();
      const ctor = await customElements.whenDefined(tag);
      const el = document.createElement(tag);
      if (wasm) el.setAttribute("wasm", new URL(`${base}graph_wasm.wasm`, location.href).href);
      el.style.cssText = "display:block;width:100%;height:100%";
      document.getElementById("host")?.appendChild(el);
      w.__el = el;
      const host = el as unknown as Record<string, unknown>;
      return {
        definedBefore,
        upgraded: el instanceof ctor,
        exports: Object.keys(mod).sort(),
        HOST_API: mod.HOST_API as unknown,
        OPEN_VIAS: mod.OPEN_VIAS as unknown,
        hostApi: host.hostApi,
        connected: host.studio !== null && host.view !== null,
      };
    },
    { tag: TAG, events: EVENTS, wasm: opts.wasm },
  );
}

type Settled = { ok: true; value: unknown } | { ok: false; name: string; message: string };

/** Calls `loadGraph(doc)` on the mounted element and settles to a plain record. */
function loadGraph(page: Page, doc: object): Promise<Settled> {
  return page.evaluate(async (d) => {
    const el = (window as unknown as { __el: { loadGraph(doc: object): Promise<unknown> } }).__el;
    try {
      return { ok: true as const, value: await el.loadGraph(d) };
    } catch (error) {
      const e = error as Error;
      return { ok: false as const, name: e.name, message: e.message };
    }
  }, doc);
}

/** Resolves with the `count`-th `name` event seen on document, or throws after WAIT_MS. */
function nthEvent(page: Page, name: string, count = 1): Promise<Recorded> {
  return page.evaluate(
    ({ name, count, ms }) =>
      new Promise<Recorded>((resolve, reject) => {
        const w = window as unknown as { __events: Recorded[] };
        const seen = () => w.__events.filter((e) => e.type === name)[count - 1];
        const now = seen();
        if (now) return resolve(now);
        const timer = setTimeout(() => reject(new Error(`no ${name} #${count} within ${ms} ms`)), ms);
        document.addEventListener(name, () => {
          const hit = seen();
          if (hit) {
            clearTimeout(timer);
            resolve(hit);
          }
        });
      }),
    { name, count, ms: WAIT_MS },
  );
}

function recorded(page: Page, name: string): Promise<Recorded[]> {
  return page.evaluate((n) => (window as unknown as { __events: Recorded[] }).__events.filter((e) => e.type === n), name);
}

/** The adapter's output shape for an osionos page tree: every member set, snake_case, and the
 *  bridge's child→parent `parent` edges as hierarchy edges with child_first:true (PLAN T4/G2). */
function node(id: string, label: string) {
  return { id, kind: "record", database_id: null, source: "osionos", label, group: "page", weight: 0.5, version: 0, has_note: false, icon: null };
}
function parentEdge(id: string, child: string, parent: string) {
  return { id, source: child, target: parent, kind: "hierarchy", label: "parent", strength: 0.5, directed: true, record_id: null, child_first: true };
}
const VALID = {
  version: 1,
  nodes: [node("p:root", "Root"), node("p:a", "A"), node("p:b", "B"), node("p:a1", "A1")],
  edges: [parentEdge("e:a", "p:a", "p:root"), parentEdge("e:b", "p:b", "p:root"), parentEdge("e:a1", "p:a1", "p:a")],
};

function watchPage(page: Page) {
  const errors: string[] = [];
  const wasm: { url: string; status: number; type: string }[] = [];
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(`console: ${m.text()}`);
  });
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.context().on("response", (r) => {
    if (r.url().endsWith(".wasm")) wasm.push({ url: new URL(r.url()).pathname, status: r.status(), type: r.headers()["content-type"] ?? "" });
  });
  return { errors, wasm };
}

test("the element upgrades, connects and speaks the contract's host API version", async ({ page }) => {
  const seen = watchPage(page);
  const m = await mount(page, { wasm: true });
  expect(m.definedBefore, "the pack must not define the element on import").toBe(false);
  expect(m.upgraded).toBe(true);
  expect(m.connected, "studio and view exist once connected").toBe(true);
  expect(m.HOST_API).toBe(CONTRACT.versions.host_api.value);
  expect(m.hostApi).toBe(CONTRACT.versions.host_api.value);
  expect(m.OPEN_VIAS).toEqual(CONTRACT.versions.open_vias.value);
  expect(m.exports).toEqual(CONTRACT.element.entry_exports.map((e) => e.value).sort());
  const missing = await page.evaluate(
    (names) => names.filter((n) => !(n in (window as unknown as { __el: object }).__el)),
    Object.keys(CONTRACT.host_members),
  );
  expect(missing, "host members the contract lists").toEqual([]);
  expect(seen.errors).toEqual([]);
});

test("(a) a valid graph with child_first parent edges loads through the wasm, without console errors", async ({ page }) => {
  const seen = watchPage(page);
  await mount(page, { wasm: true });
  const result = await loadGraph(page, VALID);
  expect(result).toEqual({ ok: true, value: { nodes: 4, edges: 3, notes: [] } });
  const load = await nthEvent(page, "graph-load");
  const { bubbles, composed } = CONTRACT.events.init.value;
  expect(load).toEqual({ type: "graph-load", detail: { nodes: 4, edges: 3, notes: [] }, bubbles, composed });
  expect(await recorded(page, "graph-load")).toHaveLength(1);
  expect(await recorded(page, "graph-error")).toEqual([]);
  // The load went through the motor: the serial wasm was fetched from the base, as wasm, once.
  expect(seen.wasm).toEqual([{ url: `/graph-studio/${CONTRACT.source_rev}/graph_wasm.wasm`, status: 200, type: "application/wasm" }]);
  const canvas = await page.evaluate(() => {
    const c = (window as unknown as { __el: HTMLElement }).__el.shadowRoot?.querySelector("canvas");
    return c ? { w: c.clientWidth, h: c.clientHeight } : null;
  });
  expect(canvas?.w).toBeGreaterThan(0);
  expect(canvas?.h).toBeGreaterThan(0);
  expect(seen.errors).toEqual([]);
});

test("(a') focusNode, selectNodes → node-select and Enter → node-open speak host ids", async ({ page }) => {
  await mount(page, { wasm: true });
  expect((await loadGraph(page, VALID)).ok).toBe(true);
  const calls = await page.evaluate(async () => {
    const el = (window as unknown as { __el: { focusNode(id: string): Promise<boolean>; selectNodes(ids: string[]): Promise<boolean>; selectedIds: readonly string[] } }).__el;
    const known = await el.focusNode("p:a1");
    const unknown = await el.focusNode("p:nope");
    const selected = await el.selectNodes(["p:b"]);
    const refused = await el.selectNodes(["p:b", "p:nope"]);
    return { known, unknown, selected, refused, ids: [...el.selectedIds] };
  });
  expect(calls).toEqual({ known: true, unknown: false, selected: true, refused: false, ids: ["p:b"] });
  const selects = (await recorded(page, "node-select")).map((e) => e.detail);
  expect(selects.at(-1)).toEqual({ ids: ["p:b"] });
  await page.evaluate(() => (window as unknown as { __el: HTMLElement }).__el.focus());
  await page.keyboard.press("Enter");
  const open = await nthEvent(page, "node-open");
  expect(open.detail).toEqual({ id: "p:b", via: "enter" });
  expect(CONTRACT.versions.open_vias.value).toContain("enter");
});

for (const bad of [
  {
    name: "(b) a duplicate node id",
    template: CONTRACT.ingest.refuse_duplicate_node_id.value,
    doc: { ...VALID, nodes: [...VALID.nodes, node("p:a", "A again")] },
    names: '"p:a"',
  },
  {
    name: "(c) a dangling edge",
    template: CONTRACT.ingest.refuse_dangling_endpoint.value,
    doc: { ...VALID, edges: [...VALID.edges, parentEdge("e:x", "p:ghost", "p:root")] },
    names: '"p:ghost"',
  },
]) {
  test(`${bad.name} refuses the whole graph as the static contract says`, async ({ page }) => {
    await mount(page, { wasm: true });
    const result = await loadGraph(page, bad.doc);
    const name = CONTRACT.rejection.load_graph_rejection_name.value;
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.name).toBe(name);
    expect(result.message).toMatch(refusalRegex(bad.template));
    expect(result.message).toContain(bad.names);
    const error = await nthEvent(page, "graph-error");
    expect(error.detail).toEqual({ error: name, message: result.message });
    // A barrier, not a sleep: a valid load after the refusal resolves with its own graph-load, and
    // by then no second graph-error and no graph-load for the refused document has been sent.
    expect((await loadGraph(page, VALID)).ok).toBe(true);
    await nthEvent(page, "graph-load");
    expect(await recorded(page, "graph-error")).toHaveLength(1);
    expect(await recorded(page, "graph-load")).toHaveLength(1);
  });
}

test("control (D9): without the wasm attribute the motor is looked up beside the page, and the load fails", async ({ page }) => {
  const seen = watchPage(page);
  await mount(page, { wasm: false });
  const result = await loadGraph(page, VALID);
  expect(result.ok).toBe(false);
  if (result.ok) return;
  const error = await nthEvent(page, "graph-error");
  expect((error.detail as { error: string }).error).toBe(result.name);
  expect(seen.wasm.map((w) => [w.url, w.status])).toContainEqual(["/graph_wasm.wasm", 404]);
  expect(await recorded(page, "graph-load")).toEqual([]);
});
