#!/usr/bin/env python3
"""Emit SQL for the SHARED 'Delivery Wiki' pages (stdout -> psql on the root
stack postgres).

The wiki showcases the notion-database-sys system end to end: the Milestones
and Files databases (relations both ways, formulas, rollups, buttons) live in
the app seed (wikiSeed.ts); these pages embed their views as database_inline /
database_full_page blocks — boards, a timeline, a gallery collection, a
calendar, and the relation-filtered "notes of milestone X" tables.

Usage: seed_delivery_wiki.py <workspace_id> <owner_id>
Pages are uuid5-stable and upserted (ON CONFLICT DO UPDATE), so re-runs
refresh content in place. visibility='shared' puts them in the Shared bucket.
"""
import base64
import json
import sys
import uuid

WS, OWNER = sys.argv[1:3]
NS = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")


def b64(payload) -> str:
    return base64.b64encode(json.dumps(payload).encode()).decode()


def q(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def pid(key: str) -> str:
    return str(uuid.uuid5(NS, f"delivery-wiki:{key}"))


def page_sql(key, parent_key, title, icon, surface, content, cover=None) -> str:
    cover_sql = q(cover) if cover else "NULL"
    parent = "NULL" if parent_key is None else q(pid(parent_key))
    return (
        "INSERT INTO public.osionos_pages"
        " (id, workspace_id, parent_page_id, owner_id, title, icon, cover, surface,"
        " visibility, collaborators, properties, content, created_at, updated_at) VALUES ("
        f"{q(pid(key))}, {q(WS)}, {parent}, {q(OWNER)},"
        f" {q(title)}, {q(icon)}, {cover_sql}, {q(surface)}, 'shared', '[]'::jsonb,"
        f" convert_from(decode('{b64([])}','base64'),'utf8')::jsonb,"
        f" convert_from(decode('{b64(content)}','base64'),'utf8')::jsonb, now(), now())"
        " ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, icon = EXCLUDED.icon,"
        " cover = EXCLUDED.cover, content = EXCLUDED.content,"
        " parent_page_id = EXCLUDED.parent_page_id, visibility = EXCLUDED.visibility,"
        " updated_at = now();"
    )


B = 0


def blk(type_, content="", **extra):
    global B
    B += 1
    return {"id": f"dw-{B:03d}", "type": type_, "content": content, **extra}


def db(view_id, database_id, full=False):
    return blk("database_full_page" if full else "database_inline", "",
               databaseId=database_id, viewId=view_id)


H1, H2, H3, P, C, D = "heading_1", "heading_2", "heading_3", "paragraph", "callout", "divider"

home = [
    blk(H1, "Delivery Wiki"),
    blk(P, "The **single shared source of truth** for what we ship and every artifact "
           "produced on the way. Two databases power it: **🎯 Milestones** and the "
           "**🗂️ Files** table — a filesystem where every entry has a *Source* "
           "(notes, documents, images, datasets) and a *relation* to its milestone."),
    blk(C, "**How it works** — the two databases are linked by a two-way relation. "
           "Rollups count each milestone's files and sum their size, formulas compute "
           "health and ages, and every view below is just a different lens over the "
           "same rows. Edit anywhere, it updates everywhere."),
    blk(D),
    blk(H2, "🗺️ Roadmap"),
    blk(P, "Milestones from start to due date — the timeline reads left to right, the "
           "*Health* formula flags anything overdue or within two weeks."),
    db("v-wiki-ms-timeline", "db-milestones"),
    blk(H2, "📌 Status Board"),
    db("v-wiki-ms-board", "db-milestones"),
    blk(H2, "📋 Every Milestone"),
    blk(P, "The full table: rollup columns (*File Count*, *Total KB*) aggregate the "
           "related Files rows; *Days Left* and *Health* are live formulas; *Brief* "
           "is a button property."),
    db("v-wiki-ms-table", "db-milestones"),
    blk(D),
    blk(H2, "🔬 Milestone Deep Dives"),
    blk(P, "The wiki's signature trick: views **filtered by relation**. Each table "
           "below shows ONLY the notes (Source = Note) whose Milestone relation "
           "points at one specific milestone."),
    blk(H3, "📝 Notes — Venus (Realtime Sync)"),
    db("v-wiki-notes-venus", "db-wikifiles"),
    blk(H3, "📝 Notes — Mars (Plugin SDK)"),
    db("v-wiki-notes-mars", "db-wikifiles"),
    blk(C, "Want the same lens on another milestone? Duplicate one of these views and "
           "change the relation filter — two clicks in the view menu."),
]

files_page = [
    blk(H1, "The Filesystem"),
    blk(P, "Every artifact the team produces, in one table. *Source* says what kind "
           "of thing it is, *Weight* is a size formula, *Age* counts days since the "
           "last edit, and *Pinned* keeps the load-bearing few on top."),
    blk(H2, "🖼️ Collection"),
    blk(P, "The gallery view — browse files as cards, heaviest first."),
    db("v-wiki-files-gallery", "db-wikifiles"),
    blk(H2, "🧭 By Source"),
    db("v-wiki-files-board", "db-wikifiles"),
    blk(H2, "🗓️ Activity Calendar"),
    blk(P, "Files plotted on their last-modified date — the team's pulse."),
    db("v-wiki-files-calendar", "db-wikifiles"),
    blk(H2, "📌 Pinned"),
    db("v-wiki-files-pinned", "db-wikifiles"),
    blk(D),
    blk(H2, "🗃️ Everything"),
    db("v-wiki-files-table", "db-wikifiles"),
]

milestones_full = [
    blk(P, "Full-page milestone tracker — switch tabs for the board, roadmap and table."),
    db("v-wiki-ms-table", "db-milestones", full=True),
]

COVER = ("https://images.unsplash.com/photo-1454165804606-c3d57bc86b40"
         "?auto=format&fit=crop&w=1600&q=80")

statements = ["BEGIN;",
              page_sql("home", None, "Delivery Wiki", "📖", "page", home, cover=COVER),
              page_sql("files", "home", "The Filesystem", "🗂️", "page", files_page),
              page_sql("milestones", "home", "Milestone Tracker", "🎯", "page", milestones_full),
              "COMMIT;"]
print("\n".join(statements))
