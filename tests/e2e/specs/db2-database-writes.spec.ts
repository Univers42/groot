import type { Page } from "@playwright/test";
import { DEMO_SKIP_REASON, E2E_DEMO_PASSWORD } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { bridge, listMounts, mountNamed, openAsDemo, rowOp, type OsionosSession } from "../lib/osionos-api";

// DB2 — osionos writes into every mounted engine through the bridge. Where the engine has
// schema DDL, a CRM table is created inside the mounted database, filled, queried, updated,
// trimmed and dropped; MSSQL and DynamoDB answer 422 unsupported_capability to DDL (measured
// 2026-10-11), so there one marked row goes into an existing table and comes out again.
// Leaves nothing: the table is dropped and the row deleted in `finally`, even on failure.

const DDL_MOUNTS = ["pg-commerce", "agency-db", "mysql-ops", "mongo-activity", "osionos-restaurant"];

const DEALS = [
  { id: 1, company: "Acme Corp", stage: "lead", deal_cents: 120000, won: false },
  { id: 2, company: "Globex", stage: "proposal", deal_cents: 450000, won: false },
  { id: 3, company: "Initech", stage: "lead", deal_cents: 80000, won: false },
];

const CRM_COLUMNS = [
  { name: "id", normalized_type: "integer" },
  { name: "company", normalized_type: "text" },
  { name: "stage", normalized_type: "text" },
  { name: "deal_cents", normalized_type: "integer" },
  { name: "won", normalized_type: "boolean" },
];

async function ddl(page: Page, s: OsionosSession, dbId: string, body: Record<string, unknown>): Promise<void> {
  await bridge(page, s, "POST", `/api/databases/${dbId}/schema/ddl`, body);
}

async function tableNames(page: Page, s: OsionosSession, dbId: string): Promise<string[]> {
  const schema = await bridge(page, s, "GET", `/api/databases/${dbId}/schema`);
  return ((schema.tables ?? []) as { name: string }[]).map((t) => t.name);
}

test.describe("DB2 osionos writes into every mounted engine", () => {
  test.skip(!E2E_DEMO_PASSWORD, DEMO_SKIP_REASON);

  for (const name of DDL_MOUNTS) {
    test(`DB2 ${name}: a CRM table is created inside the database, filled, queried, updated and dropped`, async ({ browser, consoleGuard }) => {
      const { context, page, session } = await openAsDemo(browser);
      consoleGuard.watch(page, "osionos demo");
      const mount = mountNamed(await listMounts(page, session), name);
      const table = `e2e_crm_${Date.now()}`;
      let created = false;
      try {
        await ddl(page, session, mount.dbId, { op: "create_table", table, columns: CRM_COLUMNS, primary_key: ["id"] });
        created = true;
        for (const deal of DEALS) await rowOp(page, session, mount.dbId, table, { op: "insert", data: deal });
        expect(await tableNames(page, session, mount.dbId), "the schema shows the new table").toContain(table);

        const rows = await rowOp(page, session, mount.dbId, table, { op: "list", sort: { id: "asc" }, limit: 10 });
        expect(rows.map((r) => r.company)).toEqual(DEALS.map((d) => d.company));
        const leads = await rowOp(page, session, mount.dbId, table, { op: "list", filter: { stage: "lead" }, limit: 10 });
        expect(leads.map((r) => Number(r.id)).sort()).toEqual([1, 3]);
        const totals = await rowOp(page, session, mount.dbId, table, {
          op: "aggregate",
          aggregate: { aggregates: [{ func: "count", alias: "deals" }, { func: "sum", field: "deal_cents", alias: "pipeline" }] },
        });
        expect(Number(totals[0]?.deals), "count").toBe(3);
        expect(Number(totals[0]?.pipeline), "sum of deal_cents").toBe(650000);

        await rowOp(page, session, mount.dbId, table, { op: "update", filter: { id: 2 }, data: { stage: "won", won: true } });
        const [globex] = await rowOp(page, session, mount.dbId, table, { op: "get", filter: { id: 2 } });
        expect(globex?.stage).toBe("won");
        expect(Boolean(globex?.won), "won is true (0/1 on SQL engines)").toBe(true);

        await rowOp(page, session, mount.dbId, table, { op: "delete", filter: { id: 3 } });
        const left = await rowOp(page, session, mount.dbId, table, { op: "list", sort: { id: "asc" }, limit: 10 });
        expect(left.map((r) => Number(r.id))).toEqual([1, 2]);
      } finally {
        if (created) await ddl(page, session, mount.dbId, { op: "drop_table", table, confirm: true });
        if (created) expect(await tableNames(page, session, mount.dbId), "the table is gone").not.toContain(table);
        await context.close();
      }
    });
  }

  // No DDL on these engines: one marked row in an existing table. The id is checked free
  // before the insert, so the cleanup's delete can only ever match the row this test wrote.
  const MARKED = [
    { name: "osionos-finance", table: "cost_centers", id: () => 900_000_000 + (Date.now() % 1_000_000), row: { name: "e2e cost center", region: "e2e" }, edit: { region: "e2e-updated" } },
    { name: "osionos-iot", table: "alerts", id: () => `e2e-${Date.now()}`, row: { code: 0, device_ref: "e2e", level: "info" }, edit: { level: "e2e-updated" } },
  ] as const;

  for (const spec of MARKED) {
    test(`DB2 ${spec.name}: a marked row is inserted, read, updated and deleted`, async ({ browser, consoleGuard }) => {
      const { context, page, session } = await openAsDemo(browser);
      consoleGuard.watch(page, "osionos demo");
      const mount = mountNamed(await listMounts(page, session), spec.name);
      const id = spec.id();
      const filter = { id };
      let inserted = false;
      try {
        expect(await rowOp(page, session, mount.dbId, spec.table, { op: "get", filter }), "the marked id is free").toEqual([]);
        await rowOp(page, session, mount.dbId, spec.table, { op: "insert", data: { id, ...spec.row } });
        inserted = true;
        const [row] = await rowOp(page, session, mount.dbId, spec.table, { op: "get", filter });
        expect(row?.id).toEqual(id);
        await rowOp(page, session, mount.dbId, spec.table, { op: "update", filter, data: spec.edit });
        const [edited] = await rowOp(page, session, mount.dbId, spec.table, { op: "get", filter });
        for (const [key, value] of Object.entries(spec.edit)) expect(edited?.[key]).toBe(value);
      } finally {
        if (inserted) await rowOp(page, session, mount.dbId, spec.table, { op: "delete", filter });
        if (inserted) expect(await rowOp(page, session, mount.dbId, spec.table, { op: "get", filter }), "the row is gone").toEqual([]);
        await context.close();
      }
    });
  }
});
