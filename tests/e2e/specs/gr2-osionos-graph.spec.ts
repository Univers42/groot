import type { Locator, Page, Response } from "@playwright/test";
import { BRIDGE_URL, E2E_EMAIL_B, E2E_PASSWORD_B, OSIONOS_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { loginOrRegister, openOsionos } from "../lib/session";

// GR2 — osionos's second brain on the live stack is graph_render's <graph-studio>, served by
// osionos-app from /graph-studio/<pin>/ and fed by the bridge (T-GR P3). The image is built with
// VITE_LEGACY_SECOND_BRAIN=false, so the legacy canvas must not appear anywhere here. Leaves
// nothing: the pages it creates are deleted, and the second user is reused across runs.

const VIEW = '[data-testid="graph-studio-view"]';
const LEGACY_CANVAS = "canvas.osio-graph__fg";
const GRAPH_ROUTE = /\/api\/graph\/(pages|data)(\?|$)/;
const pageNode = (id: string) => `osionos:osionos_pages:${id}`;

interface Session {
  jwt: string;
  workspaceId: string;
}

/** The osionos session once the handoff has landed: its bridge JWT and active workspace. */
async function session(page: Page): Promise<Session> {
  const read = () =>
    page.evaluate(() => {
      const store = (globalThis as unknown as { __playgroundUserStore?: { getState(): Record<string, () => unknown> } }).__playgroundUserStore;
      const state = store?.getState();
      const jwt = state?.activePageJwt?.() as string | null | undefined;
      const ws = state?.activeWorkspace?.() as { _id?: string } | undefined;
      return jwt && ws?._id ? { jwt, workspaceId: ws._id } : null;
    });
  await expect.poll(read, { message: "the osionos session never landed", timeout: 30_000 }).not.toBeNull();
  return (await read()) as Session;
}

async function bridge(page: Page, s: Session, method: string, path: string, body?: unknown): Promise<Record<string, unknown>> {
  const res = await page.evaluate(
    async ({ url, method, jwt, body }) => {
      const r = await fetch(url, {
        method,
        headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      return { status: r.status, json: (await r.json().catch(() => ({}))) as Record<string, unknown> };
    },
    { url: `${BRIDGE_URL}${path}`, method, jwt: s.jwt, body },
  );
  expect(res.status, `${method} ${path}`).toBeLessThan(300);
  return res.json;
}

/** A parent page and its child in the user's active workspace; deleted by the returned cleanup. */
async function pageTree(page: Page, s: Session, tag: string) {
  const stamp = `${tag}-${Date.now()}`;
  const parent = await bridge(page, s, "POST", "/api/pages", { workspaceId: s.workspaceId, title: `e2e-graph-parent-${stamp}` });
  const child = await bridge(page, s, "POST", "/api/pages", { workspaceId: s.workspaceId, title: `e2e-graph-child-${stamp}`, parentPageId: parent._id });
  const ids = { parent: String(parent._id), child: String(child._id), parentTitle: String(parent.title) };
  const cleanup = async () => {
    await bridge(page, s, "DELETE", `/api/pages/${ids.child}`);
    await bridge(page, s, "DELETE", `/api/pages/${ids.parent}`);
  };
  return { ...ids, cleanup };
}

/** The new graph is drawn, sized and loaded; the legacy one is nowhere. */
async function expectNewGraph(page: Page): Promise<Locator> {
  const view = page.locator(VIEW);
  await expect(view).toHaveAttribute("data-graph-state", "ready", { timeout: 45_000 });
  const element = view.locator("graph-studio");
  await expect(element).toHaveCount(1);
  const box = await element.boundingBox();
  expect(box?.width ?? 0, "the element has a width").toBeGreaterThan(0);
  expect(box?.height ?? 0, "the element has a height").toBeGreaterThan(0);
  await expect(page.locator(LEGACY_CANVAS), "a gate-off build draws no legacy graph").toHaveCount(0);
  return element;
}

function focusNode(element: Locator, id: string): Promise<boolean> {
  return element.evaluate((el, nodeId) => (el as unknown as { focusNode(id: string): Promise<boolean> }).focusNode(nodeId), id);
}

async function graphNodeIds(response: Response): Promise<string[]> {
  const body = (await response.json()) as { nodes?: { id: string }[] };
  return (body.nodes ?? []).map((n) => n.id);
}

test("GR2 rail → Second Brain draws the user's pages with graph_render, and Enter opens one", async ({ browser, consoleGuard }) => {
  const { context, page } = await openOsionos(browser);
  consoleGuard.watch(page, "osionos");
  const s = await session(page);
  const tree = await pageTree(page, s, "rail");
  try {
    await page.getByRole("tablist", { name: "Activity bar" }).getByRole("tab", { name: "Home", exact: true }).click();
    await page.getByRole("menuitem", { name: "Second Brain" }).click();
    const element = await expectNewGraph(page);
    expect(await focusNode(element, pageNode(tree.parent)), "the parent page is a node").toBe(true);
    expect(await focusNode(element, pageNode(tree.child)), "the child page is a node").toBe(true);
    // node-open (via Enter on the selected node) opens that page in a tab.
    await element.evaluate((el, id) => (el as unknown as { selectNodes(ids: string[]): Promise<boolean> }).selectNodes([id]), pageNode(tree.parent));
    await element.focus();
    await page.keyboard.press("Enter");
    await expect(page.locator('textarea[aria-label="Page title"]:visible').first()).toHaveValue(tree.parentTitle, { timeout: 15_000 });
  } finally {
    await tree.cleanup();
    await context.close();
  }
});

test("GR2 ?home=graph and a stored graph variant both open the new graph", async ({ browser, consoleGuard }) => {
  const linked = await openOsionos(browser, "?home=graph");
  consoleGuard.watch(linked.page, "osionos ?home=graph");
  await expectNewGraph(linked.page);
  await linked.context.close();

  const stored = await openOsionos(browser, "", {
    setup: (context) => context.addInitScript(() => localStorage.setItem("osionos.home.variant", "graph")),
  });
  consoleGuard.watch(stored.page, "osionos stored variant");
  await expectNewGraph(stored.page);
  expect(await stored.page.evaluate(() => localStorage.getItem("osionos.home.variant"))).toBe("graph");
  await stored.context.close();
});

test("GR2 a second user's graph holds none of the first user's pages", async ({ browser, consoleGuard }) => {
  const a = await openOsionos(browser, "?home=graph");
  consoleGuard.watch(a.page, "osionos user A");
  const sa = await session(a.page);
  const tree = await pageTree(a.page, sa, "isolation");
  try {
    // A's own graph, reloaded after the pages exist: they are in it (the positive control).
    const aGraph = a.page.waitForResponse((r) => GRAPH_ROUTE.test(r.url()) && r.request().method() === "GET");
    await a.page.reload();
    const aIds = await graphNodeIds(await aGraph);
    expect(aIds).toEqual(expect.arrayContaining([pageNode(tree.parent), pageNode(tree.child)]));
    await expectNewGraph(a.page);

    const tokenB = await loginOrRegister({ email: E2E_EMAIL_B, password: E2E_PASSWORD_B, username: "e2e-smoke-b" });
    let bGraph: Promise<Response> | undefined;
    const b = await openOsionos(browser, "?home=graph", {
      token: tokenB,
      setup: async (context) => {
        bGraph = new Promise((resolve) => context.on("response", (r) => {
          if (GRAPH_ROUTE.test(r.url()) && r.request().method() === "GET") resolve(r);
        }));
      },
    });
    consoleGuard.watch(b.page, "osionos user B");
    // Owner scoping is the rule (bridge-api handleGraphPages/handleGraphData): even a workspace
    // both users share never hands B a page A owns.
    await session(b.page);
    if (!bGraph) throw new Error("B's context was never set up");
    const bIds = await graphNodeIds(await bGraph);
    const element = await expectNewGraph(b.page);
    expect(bIds.filter((id) => id === pageNode(tree.parent) || id === pageNode(tree.child)), "A's pages in B's bridge graph").toEqual([]);
    expect(await focusNode(element, pageNode(tree.parent)), "A's page is not a node for B").toBe(false);
    expect(await b.page.evaluate(() => Object.keys(localStorage).filter((k) => /snapshot|graph-studio/i.test(k))), "nothing graph-shaped persisted").toEqual([]);
    await b.context.close();
  } finally {
    await tree.cleanup();
    await a.context.close();
  }
});
test("GR2 an index.html without the graph-studio-base meta says the graph is unavailable, never blank", async ({ browser, consoleGuard }) => {
  const { context, page } = await openOsionos(browser, "?home=graph", {
    setup: (ctx) =>
      ctx.route((url) => url.origin === new URL(OSIONOS_URL).origin && url.pathname === "/", async (route) => {
        const response = await route.fetch();
        const body = (await response.text()).replace(/<meta name="graph-studio-base"[^>]*>/, "");
        await route.fulfill({ response, body });
      }),
  });
  consoleGuard.watch(page, "osionos without meta");
  const view = page.locator(VIEW);
  await expect(view).toHaveAttribute("data-graph-state", "unavailable", { timeout: 30_000 });
  await expect(view.getByRole("alert")).toContainText("Graph unavailable: this build serves no graph engine");
  await expect(view.locator("graph-studio")).toHaveCount(0);
  await context.close();
});
