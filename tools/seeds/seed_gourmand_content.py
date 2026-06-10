#!/usr/bin/env python3
"""Emit SQL (stdout → psql on the ROOT stack) for the Vite & Gourmand org
workspace content: the live-database page tree, themed wikis (surface='wiki'),
and the team chat channels. Everything is uuid5-stable and upsert-shaped, so
re-runs refresh content in place (e.g. after a mount re-registration changes
the dbId inside the `baas:` block ids).

Usage:
  seed_gourmand_content.py <workspace_id> <owner_uuid> <gourmand_db_id> \
      <people_env_path>

Page visibility: org pages are 'shared' (workspace members see them through
the membership RLS). The Delivery Map page (customer PII) stays 'private'
with the owner + admins as collaborators.
"""
import base64
import json
import sys
import uuid

WS, OWNER, DB_ID, PEOPLE_ENV = sys.argv[1:5]
NS = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")


def page_uuid(slug: str) -> str:
    return str(uuid.uuid5(NS, f"gourmand:{slug}"))


def b64(payload) -> str:
    return base64.b64encode(json.dumps(payload).encode()).decode()


def q(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def load_people():
    admins, everyone = [], []
    with open(PEOPLE_ENV) as handle:
        for line in handle:
            if not line.startswith("GOURMAND_CRED_"):
                continue
            email, uid, name, ws_role, _pw = line.split("=", 1)[1].strip().split("|")
            everyone.append((uid, name, ws_role))
            if ws_role in ("owner", "admin"):
                admins.append(uid)
    return admins, everyone


ADMINS, EVERYONE = load_people()


def page_sql(slug, parent_slug, title, icon, surface, content,
             visibility="shared", collaborators=None) -> str:
    parent = "NULL" if parent_slug is None else q(page_uuid(parent_slug))
    collab = json.dumps(collaborators or [])
    return (
        "INSERT INTO public.osionos_pages"
        " (id, workspace_id, parent_page_id, owner_id, title, icon, surface,"
        " visibility, collaborators, properties, content, created_at, updated_at) VALUES ("
        f"{q(page_uuid(slug))}, {q(WS)}, {parent}, {q(OWNER)},"
        f" {q(title)}, {q(icon)}, {q(surface)}, {q(visibility)}, {q(collab)}::jsonb,"
        f" convert_from(decode('{b64([])}','base64'),'utf8')::jsonb,"
        f" convert_from(decode('{b64(content)}','base64'),'utf8')::jsonb, now(), now())"
        " ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, icon = EXCLUDED.icon,"
        " content = EXCLUDED.content, parent_page_id = EXCLUDED.parent_page_id,"
        " visibility = EXCLUDED.visibility, collaborators = EXCLUDED.collaborators,"
        " updated_at = now();"
    )


def live_page(slug, parent, title, icon, table, blurb, **kwargs) -> str:
    return page_sql(slug, parent, title, icon, "page", [
        {"id": "blk-1", "type": "paragraph", "content": blurb},
        {"id": "blk-2", "type": "database_full_page", "content": "",
         "databaseId": f"baas:{DB_ID}:{table}"},
    ], **kwargs)


def wiki_page(slug, parent, title, icon, blocks) -> str:
    return page_sql(slug, parent, title, icon, "wiki", blocks)


statements = ["BEGIN;"]

# ── the live-database tree ────────────────────────────────────────────────────
statements.append(page_sql("hq", None, "Restaurant HQ", "🍽️", "folder", []))
statements.append(page_sql("hq:start", "hq", "Start here", "🚀", "page", [
    {"id": "blk-1", "type": "heading_1", "content": "Vite & Gourmand — live workspace"},
    {"id": "blk-2", "type": "paragraph", "content":
        "Every database under Restaurant HQ is the restaurant's REAL data: "
        "rows come from the production PostgreSQL and any cell you edit is "
        "written back — the website reflects it."},
    {"id": "blk-3", "type": "callout", "content":
        "Slide an order across the Pipeline board and its status changes for "
        "the customer. Edit Opening Hours and the site shows the new hours.",
     "color": "💡"},
]))
statements.append(page_sql("ops", "hq", "Operations", "📦", "folder", []))
statements.append(live_page("ops:orders", "ops", "Orders", "🧾", "Order",
    "All customer orders — slide tickets across the Pipeline board to update their status in production."))
statements.append(live_page("ops:lanes", "ops", "Board Lanes", "🗂️", "KanbanColumn",
    "The kanban lane configuration the website's own board uses (sorted by position)."))
statements.append(page_sql("kitchen", "hq", "Kitchen", "👨‍🍳", "folder", []))
statements.append(live_page("kitchen:menus", "kitchen", "Menus", "📖", "Menu",
    "Published and draft menus; the seasonal timeline plans availability windows."))
statements.append(live_page("kitchen:dishes", "kitchen", "Dishes", "🍛", "Dish",
    "Every dish, grouped by course on the board."))
statements.append(page_sql("staff", "hq", "Staff", "🧑‍💼", "folder", []))
statements.append(live_page("staff:hours", "staff", "Opening Hours", "🕐", "WorkingHours",
    "The hours the website shows customers — edits go live."))
statements.append(live_page("staff:timeoff", "staff", "Time Off", "🌴", "TimeOffRequest",
    "Requests on the absence calendar; approve by sliding pending → approved."))
statements.append(live_page("staff:tickets", "staff", "Support Tickets", "🎫", "SupportTicket",
    "Customer support queue with priority and category dashboards."))
statements.append(page_sql("customers", "hq", "Customers", "🤝", "folder", []))
statements.append(live_page("customers:map", "customers", "Delivery Map", "🗺️", "UserAddress",
    "Customer delivery addresses on the map — RESTRICTED: contains personal data (GDPR).",
    visibility="private", collaborators=ADMINS))
statements.append(live_page("customers:events", "customers", "Events", "🎉", "Event",
    "Catering events and bookings on the calendar."))

# ── themed wikis ──────────────────────────────────────────────────────────────
statements.append(page_sql("wiki", "hq", "Wikis", "📚", "folder", []))
statements.append(wiki_page("wiki:handbook", "wiki", "Restaurant Handbook", "📕", [
    {"id": "blk-1", "type": "heading_1", "content": "Restaurant Handbook"},
    {"id": "blk-2", "type": "paragraph", "content":
        "Opening procedures, hygiene (HACCP), delivery zones and the daily checklists."},
    {"id": "blk-3", "type": "heading_2", "content": "Data & GDPR"},
    {"id": "blk-4", "type": "callout", "content":
        "Customer addresses are personal data: the Delivery Map page is "
        "restricted to managers. Never export customer data outside the "
        "workspace.", "color": "⚠️"},
]))
statements.append(wiki_page("wiki:recipes", "wiki", "Recipes & Allergens", "🥗", [
    {"id": "blk-1", "type": "heading_1", "content": "Recipes & Allergens"},
    {"id": "blk-2", "type": "paragraph", "content":
        "Allergen matrices per dish live in the Dishes database; this wiki "
        "holds plating guides and substitution rules."},
]))

# ── chat channels + memberships + starter messages ───────────────────────────
CHANNELS = [
    ("general", "Annonces et vie du restaurant"),
    ("kitchen", "Coordination cuisine — menus, stocks, services"),
    ("delivery", "Tournées et livraisons du jour"),
    ("front-of-house", "Salle, réservations, accueil"),
    ("support", "Tickets clients et réclamations"),
]
for name, topic in CHANNELS:
    cid = str(uuid.uuid5(NS, f"gourmand:chan:{name}"))
    statements.append(
        "INSERT INTO public.osionos_channels (id, workspace_id, kind, name, topic, created_by, is_private, abac)"
        f" VALUES ({q(cid)}, {q(WS)}, 'text', {q(name)}, {q(topic)}, {q(OWNER)}, false, '{{}}'::jsonb)"
        " ON CONFLICT (id) DO UPDATE SET topic = EXCLUDED.topic;"
    )
    for uid, _pname, ws_role in EVERYONE:
        role = "owner" if uid == OWNER else "member"
        statements.append(
            "INSERT INTO public.osionos_channel_members (channel_id, user_id, role)"
            f" VALUES ({q(cid)}, {q(uid)}, {q(role)}) ON CONFLICT DO NOTHING;"
        )
general_id = str(uuid.uuid5(NS, "gourmand:chan:general"))
welcome_id = str(uuid.uuid5(NS, "gourmand:msg:welcome"))
statements.append(
    "INSERT INTO public.osionos_messages (id, channel_id, user_id, body)"
    f" VALUES ({q(welcome_id)}, {q(general_id)}, {q(OWNER)},"
    f" {q('Bienvenue dans l’espace de travail Vite & Gourmand — les tableaux Operations sont branchés sur les vraies données du site.')})"
    " ON CONFLICT (id) DO NOTHING;"
)

statements.append("COMMIT;")
print("\n".join(statements))
