import { expect, test, type Page } from "@playwright/test";

// C7 (T-GR PLAN §8): osionos's own adapter output, through the pinned <graph-studio>, draws a
// page tree the right way up. The bridge sends page parent edges child → parent; graph_render
// reads a `parent` type parent-first, so only the adapter's child_first:true keeps the tree from
// inverting silently (crates/graph-core/src/edgekind.rs, child_first_from_type). The adapter is
// imported from the osionos submodule at its gitlink (OSIONOS_SRC), not copied.
//
// Positions come from the element's public surface only: the console switches to the tidy tree
// (the default layout is a force layout, where "above" means nothing), focusNode centres the
// parent, and node-hover names what a pointer move over the canvas lands on. Every wait is an
// event, a frame or a log line, bounded.

const WAIT_MS = 15_000;
const STEP = 12; // < the drawn node radius, so a probe cannot step over a node
const MIN_GAP = 40; // px between parent and child rows; the tidy tree here puts them ~110 px apart
const OSIONOS_SRC = process.env.OSIONOS_SRC ?? "../../apps/osionos/app";

interface Adapted {
  doc: { version: 1; nodes: { id: string }[]; edges: { id: string; child_first: boolean }[] };
  dropped: { dupNodes: number; dupEdges: number; dangling: number };
}
type ToIngestDoc = (graph: unknown) => Adapted;

async function adapter(): Promise<ToIngestDoc> {
  const url = new URL(`${OSIONOS_SRC}/src/features/graph-studio/model/toIngestDoc.ts`, `file://${process.cwd()}/`);
  return ((await import(url.href)) as { toIngestDoc: ToIngestDoc }).toIngestDoc;
}

const PARENT = "osionos:osionos_pages:11111111-0000-4000-8000-000000000001";
const CHILD = "osionos:osionos_pages:11111111-0000-4000-8000-000000000002";

function bridgePage(id: string, title: string) {
  return {
    id, mount: "osionos", resource: "osionos_pages", pk: id.split(":")[2],
    data: { id: id.split(":")[2], title, icon: null, kind: "page", visibility: "private", updatedAt: "2026-10-01T10:00:00.000Z" },
  };
}

/** A bridge /api/graph/pages answer, as scripts/bridge-graph.mjs builds it: one parent edge. */
const PAIR = {
  depth: 0, guarantee: "subgraph_eventual",
  nodes: [bridgePage(PARENT, "Parent"), bridgePage(CHILD, "Child")],
  edges: [{ id: `parent:${CHILD.split(":")[2]}`, from: CHILD, to: PARENT, type: "parent" }],
};

/** Connects one element the way osionos's host does: wasm set before it is connected. */
async function mount(page: Page): Promise<void> {
  await page.goto("/");
  await page.evaluate(async () => {
    const base = document.querySelector<HTMLMetaElement>('meta[name="graph-studio-base"]')?.content;
    if (!base) throw new Error("no graph-studio-base meta");
    const mod = await import(new URL(`${base}graph-studio.js`, location.href).href);
    mod.defineGraphStudio();
    await customElements.whenDefined("graph-studio");
    const el = document.createElement("graph-studio");
    el.setAttribute("wasm", new URL(`${base}graph_wasm.wasm`, location.href).href);
    el.style.cssText = "display:block;width:100%;height:100%";
    document.getElementById("host")?.appendChild(el);
    (window as unknown as { __el: HTMLElement }).__el = el;
  });
}

function load(page: Page, doc: object) {
  return page.evaluate((d) => (window as unknown as { __el: { loadGraph(doc: object): Promise<unknown> } }).__el.loadGraph(d), doc);
}

/** Switches to the tidy tree through the console and waits for the motor to log that run. */
async function tidyTree(page: Page): Promise<void> {
  await page.evaluate(() => (window as unknown as { __el: HTMLElement }).__el.focus());
  await page.keyboard.press("`");
  const input = page.getByLabel("Console command");
  await input.fill("layout layout.tree.tidy");
  await input.press("Enter");
  // The run's own log line (`layout.tree.tidy <n> ms`) is the settle signal; the panel title
  // naming it is the proof the console accepted the layout.
  await expect(page.getByRole("log", { name: "What the studio did" })).toContainText(/layout\.tree\.tidy \d+ ms/, { timeout: WAIT_MS });
  await expect(page.locator(".gs-action-title").filter({ hasText: /^layout\.tree\.tidy$/ })).toHaveCount(1);
  await page.getByRole("button", { name: "Close the console" }).click();
}

/**
 * How far below `parent` the element draws `child`, in screen px (negative: above). The
 * element centres `parent` (focusNode), then a narrow band through the centre is probed up and
 * down with pointer moves on its canvas, one animation frame each (node-hover is announced at
 * most once a frame), until a probe names `child`.
 */
async function childOffset(page: Page, parent: string, child: string): Promise<number> {
  const offset = await page.evaluate(
    async ({ parent, child, step }) => {
      const el = (window as unknown as { __el: HTMLElement & { focusNode(id: string): Promise<boolean> } }).__el;
      const canvas = el.shadowRoot?.querySelector("canvas");
      if (!canvas) throw new Error("the element drew no canvas");
      let hovered: string | null = null;
      el.addEventListener("node-hover", (e) => { hovered = (e as CustomEvent<{ id: string | null }>).detail.id; });
      const frame = () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      const probe = async (x: number, y: number) => {
        canvas.dispatchEvent(new PointerEvent("pointermove", { clientX: x, clientY: y, bubbles: true, pointerType: "mouse" }));
        await frame();
        return hovered;
      };
      if (!(await el.focusNode(parent))) throw new Error(`focusNode(${parent}) found no node`);
      const r = canvas.getBoundingClientRect();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      // The centring may animate: settled once the centre names the parent twice running.
      for (let tries = 0, run = 0; run < 2; tries += 1) {
        if (tries > 300) throw new Error("the parent never settled at the canvas centre");
        run = (await probe(cx, cy)) === parent ? run + 1 : 0;
      }
      for (let k = 1; k * step < r.height / 2; k += 1) {
        for (const dir of [1, -1]) {
          for (const dx of [0, -step, step]) {
            if ((await probe(cx + dx, cy + dir * k * step)) === child) return dir * k * step;
          }
        }
      }
      return null;
    },
    { parent, child, step: STEP },
  );
  if (offset === null) {
    await page.screenshot({ path: test.info().outputPath("child-not-found.png") });
    throw new Error(`no probe through the centred parent named ${child}`);
  }
  return offset;
}

test.use({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });

test("C7: the adapter's parent edge draws the parent above its child in the tidy tree", async ({ page }) => {
  const { doc, dropped } = (await adapter())(PAIR);
  expect(dropped).toEqual({ dupNodes: 0, dupEdges: 0, dangling: 0 });
  expect(doc.edges).toEqual([expect.objectContaining({ source: CHILD, target: PARENT, kind: "hierarchy", child_first: true })]);
  await mount(page);
  expect(await load(page, doc)).toEqual({ nodes: 2, edges: 1, notes: [] });
  await tidyTree(page);
  expect(await childOffset(page, PARENT, CHILD), "px from the parent down to its child").toBeGreaterThan(MIN_GAP);
});

test("C7 control: the same pair with child_first flipped draws the child on top (the check can fail)", async ({ page }) => {
  const { doc } = (await adapter())(PAIR);
  const flipped = { ...doc, edges: doc.edges.map((e) => ({ ...e, child_first: false })) };
  await mount(page);
  expect(await load(page, flipped)).toEqual({ nodes: 2, edges: 1, notes: [] });
  await tidyTree(page);
  expect(await childOffset(page, PARENT, CHILD), "px from the parent down to its child").toBeLessThan(-MIN_GAP);
});

test("the adapter's output for a messy bridge graph loads through the wasm with no note", async ({ page }) => {
  const tag = { id: "osionos:tags:work", mount: "osionos", resource: "tags", pk: "work", data: { name: "work" } };
  const folder = { id: "osionos:osionos_pages:f0", mount: "osionos", resource: "folders", pk: "f0", data: { title: "Docs", kind: "folder" } };
  const record = { id: "db1:orders:7", mount: "db1", resource: "orders", pk: "7", data: { name: "Order 7" } };
  const messy = {
    nodes: [bridgePage(PARENT, "Parent"), bridgePage(CHILD, "Child"), bridgePage(PARENT, "Parent again"), tag, folder, record],
    edges: [
      ...PAIR.edges,
      { id: `parent:${CHILD.split(":")[2]}`, from: PARENT, to: CHILD, type: "parent" }, // duplicate id
      { id: "ghost", from: CHILD, to: "osionos:osionos_pages:gone", type: "parent" }, // dangling
      { id: "t", from: CHILD, to: tag.id, type: "tagged" },
      { id: "r", from: record.id, to: PARENT, type: "relation" },
      { id: "l", from: PARENT, to: folder.id, type: "note_link" },
      { id: "o", from: folder.id, to: record.id, type: "note_of" },
      { id: "c", from: folder.id, to: PARENT, type: "child_of" },
      { id: "p", from: PARENT, to: record.id, type: "parent_of" },
      { from: record.id, to: tag.id, type: "fk_owner" }, // no id: synthesised
    ],
  };
  const { doc, dropped } = (await adapter())(messy);
  expect(dropped).toEqual({ dupNodes: 1, dupEdges: 1, dangling: 1 });
  await mount(page);
  expect(await load(page, doc)).toEqual({ nodes: doc.nodes.length, edges: doc.edges.length, notes: [] });
  expect(doc.nodes.length).toBe(5);
  expect(doc.edges.length).toBe(8);
});
