#!/usr/bin/env python3
"""Company Wiki seeder — a governed knowledge base (Notion-style wiki) for
dylan's workspace, exercising every editor component against real content.

The wiki root uses surface='wiki' (opens onto its index AND groups children —
see models/osionos-wiki-surface-migration.sql). Sections are folders; the ~50
articles are pages whose `properties` carry the wiki governance schema
(owner / status / last-verified / domain / related). Content embeds known
database views (v-*), LIVE baas mounts, layout dashboards, mermaid diagrams,
equations, tables, code, toggles, columns — the whole block vocabulary.

Idempotent: page ids are uuid5 of their slug; INSERT ... ON CONFLICT DO UPDATE.
Emits SQL to temp/seed_wiki.sql (apply with: make wiki-seed).
"""
import base64
import json
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1].parent
WS = "3f009d03-d954-5e35-85b8-db5c37aa859f"
OWNER = "ff284cf3-ab7d-4756-ade3-369257e36b2a"  # dylan@gmail.com
NS = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")
ROOT_SLUG = "company-wiki"
VERIFIED_DEFAULT = "2026-06-02"

# ---- live mounts (re-resolved from the app .env each run) -------------------
LIVE_FALLBACK = {
    "pg-commerce": "472138fd-83f5-497c-a8c2-2cd343285b65",
    "mysql-ops": "3569d015-da4f-4d05-87c1-cdcfe19597d6",
    "mongo-activity": "781b70bd-6598-4076-88c6-e1d441492c84",
}


def live_mounts() -> dict:
    env = ROOT / "apps/osionos/app/.env"
    try:
        m = re.search(r"^VITE_BAAS_LIVE_MOUNTS=(.+)$", env.read_text(), re.M)
        return {e["name"]: e["dbId"] for e in json.loads(m.group(1))}
    except Exception:
        return dict(LIVE_FALLBACK)


LIVE = live_mounts()

# known database views (databaseViewCatalog.meta.ts) — prefix → databaseId
VIEW_DB_PREFIX = {"v-tasks": "db-tasks", "v-crm": "db-crm", "v-content": "db-content",
                  "v-inv": "db-inventory", "v-prod": "db-products", "v-proj": "db-projects"}


def view_db(view_id: str) -> str:
    for prefix, db in VIEW_DB_PREFIX.items():
        if view_id.startswith(prefix):
            return db
    raise KeyError(view_id)


# ---- block toolkit (matches entities/block ReadOnlyBlock exactly) -----------
_bid = 0


def bid() -> str:
    global _bid
    _bid += 1
    return f"w-{_bid}"


def B(t, content="", **x):
    return {"id": bid(), "type": t, "content": content, **x}


def h1(t): return B("heading_1", t)
def h2(t): return B("heading_2", t)
def h3(t): return B("heading_3", t)
def p(t): return B("paragraph", t)
def bullet(t, kids=None): return B("bulleted_list", t, **({"children": kids} if kids else {}))
def numbered(t, kids=None): return B("numbered_list", t, **({"children": kids} if kids else {}))
def todo(t, done=False): return B("to_do", t, checked=done)
def quote(t): return B("quote", t)
def divider(): return B("divider")
def equation(latex): return B("equation", latex)


def callout(icon, t, kids=None, level=None):
    b = B("callout", t, color=icon)
    if kids:
        b["children"] = kids
    if level:
        b["headingLevel"] = level
    return b


def code(lang, src, fname=None, theme="dark"):
    b = B("code", src, language=lang, lineNumbers=True, codeTheme=theme, codeView="source")
    if fname:
        b["fileName"] = fname
    return b


def mermaid(src):
    return B("code", src, language="mermaid", codeView="preview", lineNumbers=False)


def toggle(t, kids, collapsed=True):
    return B("toggle", t, children=kids, collapsed=collapsed)


def columns(*cols):
    return B("column_list", children=[B("column", widthRatio=r, children=bl) for r, bl in cols])


def table(headers, rows, aligns=None):
    cfg = {"headerRow": True, "showBorders": True, "stripedRows": True}
    if aligns:
        cfg["columnAlignments"] = aligns
    return B("table_block", tableData=[list(map(str, headers))] + [list(map(str, r)) for r in rows],
             tableConfig=cfg)


def image(url, caption=""):
    return B("image", caption, asset=url)


def view_block(view_id):
    return B("database_inline", "", databaseId=view_db(view_id), viewId=view_id)


def live_block(mount, tbl, full=False):
    db_id = LIVE.get(mount, LIVE_FALLBACK[mount])
    return B("database_full_page" if full else "database_inline", "",
             databaseId=f"baas:{db_id}:{tbl}")


# ---- DSL: compact item tuples → blocks --------------------------------------
def render_items(items):
    out = []
    for it in items:
        tag = it[0]
        if tag == "p":
            out.append(p(it[1]))
        elif tag == "b":
            out.extend(bullet(x) for x in it[1:])
        elif tag == "n":
            out.extend(numbered(x) for x in it[1:])
        elif tag == "c":
            out.append(callout(it[1], it[2], kids=render_items(it[3]) if len(it) > 3 else None))
        elif tag == "t":
            out.append(table(it[1], it[2], it[3] if len(it) > 3 else None))
        elif tag == "code":
            out.append(code(it[1], it[2], it[3] if len(it) > 3 else None))
        elif tag == "mm":
            out.append(mermaid(it[1]))
        elif tag == "eq":
            out.append(callout("🧮", f"**{it[2]}**"))
            out.append(equation(it[1]))
        elif tag == "todo":
            out.extend(todo(t, d) for t, d in it[1])
        elif tag == "tg":
            out.append(toggle(it[1], render_items(it[2])))
        elif tag == "cols":
            out.append(columns(*[(r, render_items(blk)) for r, blk in it[1]]))
        elif tag == "q":
            out.append(quote(it[1]))
        elif tag == "view":
            out.append(callout("◈", it[2]))
            out.append(view_block(it[1]))
        elif tag == "live":
            out.append(callout("🔌", f"**LIVE data** — {it[3]} (mount `{it[1]}`, table `{it[2]}`; edits write back to the engine)"))
            out.append(live_block(it[1], it[2]))
        elif tag == "livefull":
            out.append(callout("🔌", f"**LIVE data** — {it[3]} (mount `{it[1]}`, table `{it[2]}`)"))
            out.append(live_block(it[1], it[2], full=True))
        elif tag == "img":
            out.append(image(it[1], it[2] if len(it) > 2 else ""))
        elif tag == "d":
            out.append(divider())
        else:
            raise ValueError(f"unknown item tag {tag!r}")
    return out


# ---- article scaffold --------------------------------------------------------
STATUS_LEGEND = ("✅ Verified — the owner re-checked every claim within the review window. "
                 "🔍 In review — content is being re-verified; treat with care. "
                 "📝 Draft — not yet governed; do not rely on it for decisions.")


def meta_bar(a):
    return columns(
        (1, [callout("👤", f"**Owner**\n{a['owner']}")]),
        (1, [callout("🏷️", f"**Status**\n{a.get('status', '✅ Verified')}")]),
        (1, [callout("📅", f"**Last verified**\n{a.get('verified', VERIFIED_DEFAULT)}")]),
        (1, [callout("🗂️", f"**Domain**\n{a['domain']}")]),
    )


def kpi_strip(kpis):
    return columns(*[(1, [callout(icon, f"**{label}**\n{value}")]) for icon, label, value in kpis])


def toc_block(a):
    rows = [bullet(f"{icon} {heading}") for icon, heading, _ in a.get("secs", ())]
    rows += [bullet("✅ Operating checklist"), bullet("❓ FAQ"),
             bullet("🧾 Decision log"), bullet("🕑 Changelog & review")]
    return toggle("📑 On this page", rows, collapsed=False)


def article_blocks(a, related_titles):
    body = [
        h1(a["title"]),
        callout("🎯", f"**TL;DR** — {a['tldr']}", level=3),
        meta_bar(a),
        callout("📖", "**Wiki contract** — this article is part of the Company Wiki: it has one "
                      "accountable owner, a verification date, and a review cadence. If you ship "
                      "something that contradicts it, the wiki wins until the owner updates it. "
                      "Propose changes via a comment or the #wiki channel; the owner must re-verify "
                      "within 5 working days."),
        toc_block(a),
        divider(),
    ]
    if a.get("kpis"):
        body.append(kpi_strip(a["kpis"]))
    for text in a.get("ctx", ()):
        body.append(p(text))
    for icon, heading, items in a.get("secs", ()):
        body.append(h2(f"{icon} {heading}"))
        body.extend(render_items(items))
    if a.get("check"):
        body += [divider(), h2("✅ Operating checklist")]
        body += [todo(t, d) for t, d in a["check"]]
    if a.get("faq"):
        body += [divider(), h2("❓ FAQ")]
        body += [toggle(f"▸ {q}", [callout("💬", ans)]) for q, ans in a["faq"]]
    if a.get("decisions"):
        body += [divider(), h2("🧾 Decision log"),
                 table(["Date", "Decision", "Why", "Owner"], a["decisions"])]
    body += [divider(), h2("🕑 Changelog & review")]
    body.append(table(["Date", "Change", "By"], a.get(
        "changelog", [[a.get("verified", VERIFIED_DEFAULT), "Verified against current practice", a["owner"]]])))
    body.append(callout("⏰", f"**Review cadence** — quarterly. Next review due **2026-09-01**. "
                              f"Owner: {a['owner']}. Status legend: {STATUS_LEGEND}"))
    if related_titles:
        body += [divider(), h3("🔗 Related articles")]
        body += [bullet(f"→ {t}") for t in related_titles]
    return body


def governance_props(a, related_ids):
    props = [
        {"key": "owner", "label": "Owner", "type": "text", "value": a["owner"]},
        {"key": "status", "label": "Status", "type": "select",
         "value": a.get("status", "✅ Verified"),
         "options": ["✅ Verified", "🔍 In review", "📝 Draft"]},
        {"key": "verified", "label": "Last verified", "type": "date",
         "value": a.get("verified", VERIFIED_DEFAULT)},
        {"key": "domain", "label": "Domain", "type": "select", "value": a["domain"],
         "options": ["Company", "Engineering", "Security", "Product", "Data",
                     "Go-to-market", "People", "Finance"]},
    ]
    if related_ids:
        props.append({"key": "related", "label": "Related", "type": "relation",
                      "value": related_ids, "relationTarget": "page"})
    return props


# ---- wiki root index ----------------------------------------------------------
DASH_PLACEMENTS = [
    (1, 6, 1, 2), (7, 6, 1, 2),
    (1, 6, 3, 4), (7, 6, 3, 4),
    (1, 6, 7, 4), (7, 6, 7, 4),
]


def dash_cell(placement, label, blocks, tint):
    col, span, row, rspan = placement
    return {
        "id": bid(), "colStart": col, "colSpan": span, "rowStart": row, "rowSpan": rspan,
        "label": label, "type": "text", "content": "", "blocks": blocks,
        "sizing": "fixed", "horizontalConstraint": "stretch", "verticalConstraint": "top",
        "wrap": True, "padding": "comfortable", "fontSize": "base",
        "backgroundColor": f"color-mix(in srgb, {tint} 9%, var(--osio-bg-surface))",
        "textColor": "var(--osio-fg-default)",
    }


def root_dashboard():
    cells = [
        dash_cell(DASH_PLACEMENTS[0], "Pulse — delivery", [
            h3("🗂️ Delivery pulse"),
            p("Tasks across the org, grouped by status. Blocked items surface here before they surface in a meeting."),
            view_block("v-tasks-board")], "#2563eb"),
        dash_cell(DASH_PLACEMENTS[1], "Pulse — budget", [
            h3("◔ Budget exposure"),
            p("Committed project budget by project — the number every quarterly review starts from."),
            view_block("v-proj-chart")], "#b45309"),
        dash_cell(DASH_PLACEMENTS[2], "Catalog analytics", [
            h3("◈ Product analytics"),
            p("Catalog health: category balance, ratings, price distribution."),
            view_block("v-prod-analytics")], "#0f766e"),
        dash_cell(DASH_PLACEMENTS[3], "Editorial", [
            h3("◫ Editorial calendar"),
            p("What we publish and when — the publishing rhythm the content team commits to."),
            view_block("v-content-calendar")], "#7c3aed"),
        dash_cell(DASH_PLACEMENTS[4], "Live commerce", [
            h3("🐘 LIVE — storefront orders"),
            p("Real PostgreSQL rows through the mini-baas gateway. Edits write back to the engine."),
            live_block("pg-commerce", "orders")], "#be123c"),
        dash_cell(DASH_PLACEMENTS[5], "Live support", [
            h3("🐬 LIVE — support tickets"),
            p("Real MySQL rows: severity enums make this an instant triage board."),
            live_block("mysql-ops", "tickets")], "#0891b2"),
    ]
    return {
        "id": bid(), "type": "layout", "content": "", "layoutMode": "inline",
        "layoutConfig": {"columns": 12, "rows": 11, "gap": 16, "rowHeight": 132,
                         "wrap": True, "autoArrange": False, "snapToGrid": True,
                         "guideVisibility": "auto", "preview": False, "theme": "spacious"},
        "layoutCells": cells,
    }


def root_blocks(sections, article_count):
    section_rows = [[f"{icon} {name}", desc, str(count)] for name, icon, desc, count in sections]
    return [
        h1("Company Wiki"),
        callout("🎯", "**The single source of truth for how this company runs.** "
                      f"{article_count} governed articles across {len(sections)} domains — every one "
                      "has an accountable owner, a verification date, and a quarterly review. "
                      "If a doc matters, it lives here; if it lives here, you can trust it.", level=3),
        kpi_strip([("📚", "Articles", str(article_count)),
                   ("🗂️", "Sections", str(len(sections))),
                   ("👤", "Owners", "8 accountable leads"),
                   ("⏰", "Review cadence", "Quarterly")]),
        divider(),
        h2("📜 The rules of this wiki"),
        numbered("**A wiki is not a folder.** This root opens onto the index you are reading, and it"
                 " groups every article beneath it in the sidebar — both at once (surface = `wiki`)."),
        numbered("**Every article has exactly one owner.** Names, not teams. The owner answers for"
                 " accuracy and re-verifies quarterly."),
        numbered("**Status is explicit.** ✅ Verified / 🔍 In review / 📝 Draft — shown in each"
                 " article's meta bar and its page properties."),
        numbered("**The wiki wins conflicts.** If practice and wiki disagree, follow the wiki and"
                 " flag the owner — fixing the doc IS the fix."),
        numbered("**Articles cross-link.** Every page lists Related articles (relation properties),"
                 " so the knowledge graph stays connected — no orphan pages."),
        numbered("**Live data over screenshots.** Operational articles embed the real databases"
                 " (live mounts) and shared /views — numbers in the wiki are never stale copies."),
        toggle("📖 How verification works", [
            p("Owners re-verify their articles every quarter (next sweep: 2026-09-01). Verification "
              "means re-reading the article, re-running embedded queries/views, and bumping the "
              "Last-verified date."),
            bullet("✅ Verified — safe to act on without double-checking."),
            bullet("🔍 In review — owner is re-verifying; confirm critical claims before acting."),
            bullet("📝 Draft — structure may be right, numbers may not be. Never cite a draft."),
            p("Changing an article you don't own: propose the edit in a comment or #wiki; the owner "
              "must accept (or counter) within 5 working days."),
        ], collapsed=False),
        divider(),
        h2("🗺️ Wiki map"),
        mermaid("mindmap\n  root((Company Wiki))\n    Company Handbook\n      Mission & principles\n      Org & teams\n      Decisions\n    Engineering\n      Architecture\n      Quality gates\n      On-call\n    Security\n      Vault & secrets\n      Incident response\n    Product & Design\n      Editor spec\n      Views & live mounts\n    Data & Analytics\n      KPI dictionary\n      Dashboards\n    Sales & Support\n      CRM playbook\n      SLAs\n    People Ops\n      Onboarding\n      Hiring\n    Finance\n      Unit economics\n      Runway"),
        h2("🗂️ Section directory"),
        table(["Section", "What lives here", "Articles"], section_rows),
        divider(),
        h2("📊 Company pulse — live"),
        p("This dashboard is built from the same shared /views and LIVE database mounts the rest of "
          "the company uses — it is never a stale screenshot. Edit a cell and you are editing the "
          "source engine."),
        root_dashboard(),
        divider(),
        callout("🧭", "**Start here if you are new:** People Ops → *Onboarding: your first two weeks*, "
                      "then Company Handbook → *Mission & operating principles*, then your team's "
                      "section. Everything else you can pull when you need it."),
    ]


# ---- emission -----------------------------------------------------------------
def b64(o) -> str:
    return base64.b64encode(json.dumps(o).encode()).decode()


def jcol(o) -> str:
    return f"convert_from(decode('{b64(o)}','base64'),'utf8')::jsonb"


def sqlstr(s) -> str:
    return "'" + s.replace("'", "''") + "'"


def page_sql(pid, parent, title, icon, surface, props, content, cover=None):
    return (
        "INSERT INTO public.osionos_pages (id, workspace_id, parent_page_id, owner_id, title,"
        " icon, cover, surface, visibility, collaborators, properties, content, created_at, updated_at)"
        f" VALUES ({sqlstr(pid)}, {sqlstr(WS)}, {sqlstr(parent) if parent else 'NULL'}, {sqlstr(OWNER)},"
        f" {sqlstr(title)}, {sqlstr(icon) if icon else 'NULL'}, {sqlstr(cover) if cover else 'NULL'},"
        f" {sqlstr(surface) if surface else 'NULL'}, 'private', '[]'::jsonb,"
        f" {jcol(props)}, {jcol(content)}, now(), now())"
        " ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, icon = EXCLUDED.icon,"
        " cover = EXCLUDED.cover, surface = EXCLUDED.surface, parent_page_id = EXCLUDED.parent_page_id,"
        " properties = EXCLUDED.properties, content = EXCLUDED.content, updated_at = now();"
    )


def est_lines(blocks) -> int:
    """Rough rendered-line estimate: each block ≥1 line; lists/tables/code expand."""
    n = 0
    for blk in blocks:
        n += 1
        n += max(0, len(blk.get("content", "")) // 90)
        if blk.get("type") == "table_block":
            n += len(blk.get("tableData", []))
        if blk.get("type") == "code":
            n += blk.get("content", "").count("\n")
        for cell in blk.get("layoutCells", []) or []:
            n += est_lines(cell.get("blocks", []))
        n += est_lines(blk.get("children", []) or [])
    return n


def main() -> None:
    from seed_wiki_content import SECTIONS as S1, ARTICLES as A1
    from seed_wiki_content2 import SECTIONS as S2, ARTICLES as A2
    sections = S1 + S2
    articles = A1 + A2

    pid = lambda slug: str(uuid.uuid5(NS, f"{ROOT_SLUG}:{slug}"))
    by_slug = {a["slug"]: a for a in articles}
    title_of = {a["slug"]: a["title"] for a in articles}

    root_id = pid("root")
    section_meta = []
    for key, name, icon, desc, cover in sections:
        count = sum(1 for a in articles if a["sec"] == key)
        section_meta.append((name, icon, desc, count))

    stmts = ["BEGIN;"]
    stmts.append(page_sql(root_id, None, "Company Wiki", "📚", "wiki", [],
                          root_blocks(section_meta, len(articles)),
                          cover="https://images.unsplash.com/photo-1481627834876-b7833e8f5570?auto=format&fit=crop&w=1600&q=80"))
    for key, name, icon, desc, cover in sections:
        stmts.append(page_sql(pid(f"sec:{key}"), root_id, name, icon, "folder", [], [], cover=cover))

    total_blocks, low = 0, []
    for a in articles:
        rel_slugs = [s for s in a.get("related", ()) if s in by_slug]
        rel_ids = [pid(s) for s in rel_slugs]
        rel_titles = [title_of[s] for s in rel_slugs]
        content = article_blocks(a, rel_titles)
        lines = est_lines(content)
        total_blocks += len(content)
        if lines < 300:
            low.append((a["slug"], lines))
        stmts.append(page_sql(pid(a["slug"]), pid(f"sec:{a['sec']}"), a["title"], a["icon"],
                              None, governance_props(a, rel_ids), content, cover=a.get("cover")))
        print(f"  {a['slug']:<28} blocks={len(content):>4} est-lines={lines:>4}", file=sys.stderr)
    stmts.append("COMMIT;")

    out = ROOT / "temp/seed_wiki.sql"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(stmts) + "\n")
    print(f"wiki: 1 root + {len(sections)} sections + {len(articles)} articles | "
          f"top-level blocks total={total_blocks}", file=sys.stderr)
    if low:
        print(f"NOTE thin articles (<300 est lines): {low}", file=sys.stderr)
    print(out)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    main()
