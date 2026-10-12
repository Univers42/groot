import type { Locator, Page } from "@playwright/test";
import { expect, test } from "../lib/fixtures";
import { bridge, bridgeStatus, osionosSession, type OsionosSession } from "../lib/osionos-api";
import { loginOrRegister, openOsionos } from "../lib/session";

// OD1 — a CRM workspace made the way a user makes one. A fresh account picks New workspace →
// "For work", renames it in Settings, and types its customers into an inline `/database` table.
// The workspace, its name, its starter pages and the table's rows are on the bridge, so another
// session of the same account reads them; the suite's other user reaches none of it. Leaves the
// account and its workspaces (the bridge deletes neither; one e2e-crm-<ms>@example.com per run);
// the object database is deleted.

const PASSWORD = "E2e-Crm-Pass-2026!";
const STARTER_PAGES = ["Getting Started", "Projects", "Company Goals", "Meeting Notes"];
const CUSTOMERS = ["Acme Corp", "Globex"] as const;

interface Workspace { _id: string; name: string; role: string }
interface ObjectDatabase { dbKey: string; state: { pages?: Record<string, { properties?: Record<string, unknown> }> } }

async function workspaces(page: Page, s: OsionosSession): Promise<Workspace[]> {
  return ((await bridge(page, s, "GET", "/api/workspaces")).items ?? []) as Workspace[];
}

async function objectDatabases(page: Page, s: OsionosSession): Promise<ObjectDatabase[]> {
  return ((await bridge(page, s, "GET", "/api/object-databases")).databases ?? []) as ObjectDatabase[];
}

/** The row titles of one object database, as the bridge stores them. */
function rowTitles(db: ObjectDatabase | undefined): string[] {
  return Object.values(db?.state.pages ?? {}).flatMap((row) => Object.values(row.properties ?? {}).filter((v): v is string => typeof v === "string" && v !== ""));
}

/** Types `text` into a table cell: select it, Enter to edit, Enter to commit. */
async function fillCell(page: Page, cell: Locator, text: string) {
  await cell.click();
  await page.keyboard.press("Enter");
  await page.keyboard.type(text);
  await page.keyboard.press("Enter");
}

test("OD1 a new account builds a CRM workspace in the UI: created, renamed, a customer table, private to it", async ({ browser, consoleGuard }) => {
  test.setTimeout(240_000);
  const stamp = Date.now();
  const user = { email: `e2e-crm-${stamp}@example.com`, password: PASSWORD, username: `e2e_crm_${stamp}` };
  const crmName = `CRM ${stamp}`;
  const { context, page } = await openOsionos(browser, "", { token: await loginOrRegister(user) });
  consoleGuard.watch(page, "osionos (CRM account)");
  const s = await osionosSession(page);

  await page.getByRole("button", { name: "More workspace options" }).click();
  await page.getByRole("button", { name: "New workspace" }).click();
  await page.getByRole("dialog", { name: "What is this space for?" }).getByRole("button", { name: /^For work/ }).click();
  await expect.poll(async () => (await osionosSession(page)).workspaceId, { message: "the new workspace becomes the active one", timeout: 30_000 }).not.toBe(s.workspaceId);
  const crmId = (await osionosSession(page)).workspaceId;

  await page.getByRole("complementary", { name: "Sidebar" }).getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByRole("dialog", { name: "Settings" }).getByRole("textbox", { name: "Workspace name" }).fill(crmName);
  await expect.poll(async () => (await workspaces(page, s)).find((w) => w._id === crmId)?.name, { message: "the rename reaches the bridge", timeout: 15_000 }).toBe(crmName);
  await page.keyboard.press("Escape");

  const pages = ((await bridge(page, s, "GET", `/api/pages/all?workspaceId=${crmId}`)).items ?? []) as { title: string }[];
  expect(pages.map((p) => p.title).sort(), "the work kit's starter pages").toEqual([...STARTER_PAGES].sort());

  const known = new Set((await objectDatabases(page, s)).map((db) => db.dbKey));
  await page.getByRole("textbox", { name: "Type '/' for commands…" }).last().click();
  await page.keyboard.type("/database");
  await page.getByRole("option", { name: "Database - Inline" }).click();
  const grid = page.getByRole("grid", { name: /table — arrow keys to move/ });
  await fillCell(page, grid.getByRole("gridcell").first(), CUSTOMERS[0]);
  await grid.getByRole("button", { name: "New", exact: true }).click();
  await fillCell(page, grid.getByRole("gridcell", { name: /^Empty/ }), CUSTOMERS[1]);
  const created = async () => (await objectDatabases(page, s)).find((db) => !known.has(db.dbKey));
  await expect.poll(async () => rowTitles(await created()).sort(), { message: "the table's rows reach the bridge", timeout: 20_000 }).toEqual([...CUSTOMERS].sort());
  const dbKey = String((await created())?.dbKey);

  try {
    const again = await openOsionos(browser, "", { token: await loginOrRegister(user) });
    consoleGuard.watch(again.page, "osionos (CRM account, second session)");
    const s2 = await osionosSession(again.page);
    expect((await workspaces(again.page, s2)).find((w) => w._id === crmId), "the same account, a fresh session").toMatchObject({ name: crmName, role: "owner" });
    expect(rowTitles((await objectDatabases(again.page, s2)).find((db) => db.dbKey === dbKey)).sort()).toEqual([...CUSTOMERS].sort());
    await again.context.close();

    const other = await openOsionos(browser);
    const so = await osionosSession(other.page);
    expect((await workspaces(other.page, so)).map((w) => w._id), "another account's workspaces").not.toContain(crmId);
    expect((await objectDatabases(other.page, so)).map((db) => db.dbKey), "another account's object databases").not.toContain(dbKey);
    expect(await bridgeStatus(other.page, so, `/api/pages/all?workspaceId=${crmId}`), "another account listing the CRM pages").toBeGreaterThanOrEqual(403);
    await other.context.close();
  } finally {
    await bridge(page, s, "DELETE", `/api/object-databases/${encodeURIComponent(dbKey)}`);
    await context.close();
  }
});
