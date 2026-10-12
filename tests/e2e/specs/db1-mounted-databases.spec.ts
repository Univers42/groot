import { DEMO_SKIP_REASON, E2E_DEMO_PASSWORD } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { bridge, bridgeStatus, listMounts, openAsDemo, rowOp } from "../lib/osionos-api";

// DB1 — every database mounted on the demo account's workspaces, read the way osionos reads
// it: the bridge's list (adapter-registry), each mount's schema and every table's rows
// (query-router), the account graph's record nodes, and a record opened as its note. On a
// linked stack these cross the link to the data center (wiki/runbooks/grobase-link.md).
// Leaves nothing: a note this spec opens for the first time is deleted again.

const ENGINES = ["dynamodb", "mongodb", "mssql", "mysql", "postgresql", "sqlite"];

interface Table {
  name: string;
  primary_key?: string[];
}

test.describe("DB1 the demo account's mounted databases", () => {
  test.skip(!E2E_DEMO_PASSWORD, DEMO_SKIP_REASON);

  test("DB1 the list holds every engine, and every table of every mount answers with rows", async ({ browser, consoleGuard }) => {
    const { context, page, session } = await openAsDemo(browser);
    consoleGuard.watch(page, "osionos demo");
    try {
      const mounts = await listMounts(page, session);
      expect([...new Set(mounts.map((m) => m.engine))].sort(), "engines in /api/databases").toEqual(ENGINES);
      for (const mount of mounts) {
        const schema = await bridge(page, session, "GET", `/api/databases/${mount.dbId}/schema`);
        const tables = (schema.tables ?? []) as Table[];
        expect(tables.length, `${mount.name} (${mount.engine}) lists tables`).toBeGreaterThan(0);
        const counts: string[] = [];
        let total = 0;
        for (const table of tables) {
          const rows = await rowOp(page, session, mount.dbId, table.name, { op: "list", limit: 5 });
          counts.push(`${table.name}=${rows.length}`);
          total += rows.length;
        }
        console.log(`${mount.engine} ${mount.name}: ${counts.join(" ")}`);
        expect(total, `${mount.name} (${mount.engine}) holds rows`).toBeGreaterThan(0);
      }
    } finally {
      await context.close();
    }
  });

  test("DB1 the account graph draws records from every mount", async ({ browser, consoleGuard }) => {
    const { context, page, session } = await openAsDemo(browser);
    consoleGuard.watch(page, "osionos demo");
    try {
      const mounts = await listMounts(page, session);
      const graph = await bridge(page, session, "GET", "/api/graph/data?scope=account");
      const ids = ((graph.nodes ?? []) as { id: string }[]).map((n) => n.id);
      const perMount = mounts.map((m) => ({ m, n: ids.filter((id) => id.startsWith(`${m.dbId}:`)).length }));
      console.log(`graph ${ids.length} nodes; ${perMount.map(({ m, n }) => `${m.name}=${n}`).join(" ")}`);
      for (const { m, n } of perMount) expect(n, `${m.name} (${m.engine}) record nodes`).toBeGreaterThan(0);
    } finally {
      await context.close();
    }
  });

  test("DB1 a record opens as one note, the same note every time", async ({ browser, consoleGuard }) => {
    const { context, page, session } = await openAsDemo(browser);
    consoleGuard.watch(page, "osionos demo");
    let created: string | null = null;
    try {
      const commerce = (await listMounts(page, session)).find((m) => m.name === "pg-commerce");
      if (!commerce) throw new Error("mount pg-commerce is not listed");
      const [customer] = await rowOp(page, session, commerce.dbId, "customers", { op: "list", limit: 1, sort: { id: "desc" } });
      const pk = String(customer?.id ?? "");
      expect(pk, "a customer row to open").not.toBe("");
      const read = await bridge(page, session, "GET", `/api/records/${commerce.dbId}/customers/${pk}`);
      expect((read.row as Record<string, unknown>).id).toEqual(customer?.id);
      // A note the user already has for this record is theirs: opened, never deleted here.
      const existed = (await bridgeStatus(page, session, `/api/pages/${String(read.noteId)}`)) === 200;
      const first = await bridge(page, session, "POST", `/api/records/${commerce.dbId}/customers/${pk}/open`);
      if (!existed) created = String(first._id);
      const again = await bridge(page, session, "POST", `/api/records/${commerce.dbId}/customers/${pk}/open`);
      expect(first._id, "the note id is the record's deterministic id").toBe(read.noteId);
      expect(again._id, "opening twice is the same note").toBe(first._id);
    } finally {
      if (created) await bridge(page, session, "DELETE", `/api/pages/${created}`);
      await context.close();
    }
  });
});
