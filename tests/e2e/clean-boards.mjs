// Soft-deletes the suite's boards through the drawnosaurus API. Runs INSIDE the API
// container (make e2e-clean pipes it to `node -`), so it needs no host port or CA.
// Matches the title by exact, case-sensitive prefix. Deletes nothing unless the whole list
// was read, and refuses outright if any other title only NEARLY matches ("E2E-x", " e2e-x",
// "e2e_x"): an ambiguous board is somebody's, not the suite's.
const PREFIX = "e2e-";
const API = process.env.E2E_CLEAN_API ?? "http://127.0.0.1:4000";
const dryRun = process.argv.includes("--dry-run");

async function listAll() {
  const boards = [];
  let cursor = "";
  do {
    const query = new URLSearchParams({ limit: "100", ...(cursor ? { cursor } : {}) });
    const res = await fetch(`${API}/v1/boards?${query}`);
    if (!res.ok) throw new Error(`GET /v1/boards: HTTP ${res.status} — refusing to delete from a partial list`);
    const page = await res.json();
    boards.push(...page.boards);
    cursor = page.nextCursor ?? "";
  } while (cursor);
  return boards;
}

const boards = await listAll();
const selected = boards.filter((b) => typeof b.title === "string" && b.title.startsWith(PREFIX));
const near = boards.filter((b) => !selected.includes(b) && /^\s*e2e/i.test(String(b.title)));
if (near.length > 0) {
  console.error("[e2e-clean] refusing, nothing deleted: these titles nearly match the prefix", near.map((b) => b.title));
  process.exit(1);
}
for (const board of selected) {
  if (dryRun) { console.log(`[e2e-clean] would delete ${board.slug} "${board.title}"`); continue; }
  const res = await fetch(`${API}/v1/boards/${board.slug}`, { method: "DELETE" });
  if (res.status !== 204) { console.error(`[e2e-clean] DELETE ${board.slug}: HTTP ${res.status}`); process.exit(1); }
  console.log(`[e2e-clean] deleted ${board.slug} "${board.title}"`);
}
const left = (await listAll()).filter((b) => b.title.startsWith(PREFIX)).length;
console.log(`[e2e-clean] ${selected.length} matched, ${boards.length - selected.length} other board(s) kept, ${left} e2e- board(s) left${dryRun ? " (dry run)" : ""}`);
if (!dryRun && left !== 0) process.exit(1);
