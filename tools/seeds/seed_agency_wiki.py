#!/usr/bin/env python3
"""Binocle Intelligence Agency — Wave 2 content seeder.

Emits TWO idempotent SQL artifacts (fixed uuid5 ids, ON CONFLICT guards):
  tools/seeds/seed_agency_wiki.sql  — ~26 wiki/notebook/gallery pages in the
                                      org workspace (osionos_pages)
  tools/seeds/seed_agency_chat.sql  — channels + members + ~210 messages +
                                      reactions + feed likes/comments

Block JSON shapes mirror tools/seeds/seed_arch.py, which matches the
entities/block ReadOnlyBlock renderer exactly. Live database embeds use
`database_inline` blocks with databaseId `baas:<AGENCY_DB_ID>:<table>`
(widgets/database-view DatabaseBlock → getLiveDatabaseAdapter).

People + tenant ids are read from tools/seeds/.agency-people.env and
apps/baas/mini-baas-infra/.agency-tenant.env so re-provisioning stays in sync.
"""
import base64
import json
import os
import random
import sys
import uuid
from urllib.parse import quote as urlquote

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# --------------------------------------------------------------------------- #
#  Environment: roster + live tenant                                           #
# --------------------------------------------------------------------------- #
def read_env(path):
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k] = v
    except FileNotFoundError:
        pass
    return out

PEOPLE_ENV = read_env(os.path.join(HERE, ".agency-people.env"))
TENANT_ENV = read_env(os.path.join(ROOT, "apps/baas/mini-baas-infra/.agency-tenant.env"))

WS = PEOPLE_ENV.get("AGENCY_ORG_WORKSPACE_ID", "b1a0c1e5-0000-4000-a000-000000000001")
DB_ID = TENANT_ENV.get("AGENCY_DB_ID", "d3ecb3e1-9947-41a6-a0d3-ff2063b4adee")

# key -> (uuid, name, role, dept)
PEOPLE = {}
_KEY_BY_EMAIL = {
    "owner@agency.local": "helena", "e01.reed@agency.local": "marcus",
    "e02.lindqvist@agency.local": "sofia", "e03.okafor@agency.local": "david",
    "e04.tanaka@agency.local": "yuki", "e05.moreau@agency.local": "pierre",
    "e06.diallo@agency.local": "amara", "e07.sullivan@agency.local": "jack",
    "e08.petrova@agency.local": "nadia", "e09.becker@agency.local": "tom",
    "e10.haddad@agency.local": "leila", "e11.johansson@agency.local": "erik",
    "e12.sharma@agency.local": "priya", "e13.mendez@agency.local": "carlos",
    "e14.weiss@agency.local": "hannah", "e15.farouk@agency.local": "omar",
    "e16.liu@agency.local": "grace", "e17.antonov@agency.local": "viktor",
    "e18.romero@agency.local": "isabel", "e19.ngata@agency.local": "robert",
    "e20.kowalski@agency.local": "maya",
}
for k, v in PEOPLE_ENV.items():
    if not k.startswith("AGENCY_PERSON_") or k.endswith("_COUNT"):
        continue
    parts = v.split("|")
    if len(parts) < 5:
        continue
    pid, email, name, role, dept = parts[0], parts[1], parts[2], parts[3], parts[4]
    key = _KEY_BY_EMAIL.get(email)
    if key:
        PEOPLE[key] = (pid, name, role, dept)

def P(key):  # uuid of a person
    return PEOPLE[key][0]

def PN(key):  # display name
    return PEOPLE[key][1]

assert len(PEOPLE) == 21, f"roster incomplete: {sorted(PEOPLE)}"

# --------------------------------------------------------------------------- #
#  Deterministic ids                                                            #
# --------------------------------------------------------------------------- #
NS = uuid.uuid5(uuid.NAMESPACE_DNS, "binocle-intelligence-agency.local")
def uid(key):
    return str(uuid.uuid5(NS, key))

# --------------------------------------------------------------------------- #
#  Block toolkit (matches entities/block ReadOnlyBlock — see seed_arch.py)      #
# --------------------------------------------------------------------------- #
_bid = 0
def bid():
    global _bid
    _bid += 1
    return f"aw-{_bid}"

def B(t, content="", **x):
    return {"id": bid(), "type": t, "content": content, **x}

def h1(t): return B("heading_1", t)
def h2(t): return B("heading_2", t)
def h3(t): return B("heading_3", t)
def p(t): return B("paragraph", t)
def bullet(t, kids=None): return B("bulleted_list", t, **({"children": kids} if kids else {}))
def numbered(t, kids=None): return B("numbered_list", t, **({"children": kids} if kids else {}))
def todo(t, done=False): return B("to_do", t, checked=done)
def quote(t, level=None): return B("quote", t, **({"headingLevel": level} if level else {}))
def divider(): return B("divider")

def callout(icon, t, kids=None, level=None):
    b = B("callout", t, color=icon)
    if kids:
        b["children"] = kids
    if level:
        b["headingLevel"] = level
    return b

def toggle(t, kids, collapsed=True):
    return B("toggle", t, children=kids, collapsed=collapsed)

def columns(*cols):  # cols = (widthRatio, [blocks])
    return B("column_list", children=[B("column", widthRatio=r, children=bl) for r, bl in cols])

def table(headers, rows, aligns=None):
    cfg = {"headerRow": True, "showBorders": True, "stripedRows": True}
    if aligns:
        cfg["columnAlignments"] = aligns
    return B("table_block", tableData=[list(map(str, headers))] + [list(map(str, r)) for r in rows],
             tableConfig=cfg)

def live_db(tablename):
    """Embedded LIVE database block — baas:<dbId>:<table> id, resolved by
    getLiveDatabaseAdapter in widgets/database-view."""
    return B("database_inline", "", databaseId=f"baas:{DB_ID}:{tablename}")

def evidence_card(label, sub, color):
    """Offline-rendering SVG 'evidence scan' as a data: URL image block."""
    svg = (f"<svg xmlns='http://www.w3.org/2000/svg' width='640' height='220'>"
           f"<rect width='640' height='220' fill='{color}'/>"
           f"<rect x='14' y='14' width='612' height='192' fill='none' "
           f"stroke='white' stroke-opacity='0.5' stroke-width='2' stroke-dasharray='8 6'/>"
           f"<text x='320' y='98' font-size='30' fill='white' text-anchor='middle' "
           f"font-family='monospace'>{label}</text>"
           f"<text x='320' y='140' font-size='16' fill='white' fill-opacity='0.85' "
           f"text-anchor='middle' font-family='monospace'>{sub}</text>"
           f"<text x='320' y='190' font-size='12' fill='white' fill-opacity='0.6' "
           f"text-anchor='middle' font-family='monospace'>BINOCLE INTELLIGENCE AGENCY — SECURE SCAN</text>"
           f"</svg>")
    return B("image", f"{label} — {sub}", asset="data:image/svg+xml," + urlquote(svg, safe="'/= :;,()"))

def relation(ids):
    return [{"key": "related", "label": "Related", "type": "relation",
             "value": ids, "relationTarget": "page"}]

# --------------------------------------------------------------------------- #
#  Covers (proven URLs from backfill_covers.sql)                                #
# --------------------------------------------------------------------------- #
COVER = {
    "ops": "https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=1200&q=80",
    "handbook": "https://images.unsplash.com/photo-1517077304055-6e89abbf09b0?auto=format&fit=crop&w=1200&q=80",
    "cases": "https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&w=1200&q=80",
    "gallery": "https://images.unsplash.com/photo-1518770660439-4636190af475?auto=format&fit=crop&w=1200&q=80",
    "notebooks": "https://images.unsplash.com/photo-1542831371-29b0f74f9713?auto=format&fit=crop&w=1200&q=80",
    "night": "https://images.unsplash.com/photo-1526374965328-7f61d4dc18c5?auto=format&fit=crop&w=1200&q=80",
    "vault": "https://images.unsplash.com/photo-1550751827-4bd374c3f58b?auto=format&fit=crop&w=1200&q=80",
    "storm": "https://images.unsplash.com/photo-1504384308090-c894fdcc538d?auto=format&fit=crop&w=1200&q=80",
    "garden": "https://images.unsplash.com/photo-1635070041078-e363dbe005cb?auto=format&fit=crop&w=1200&q=80",
    "compass": "https://images.unsplash.com/photo-1564865878688-9a244444042a?auto=format&fit=crop&w=1200&q=80",
    "meridian": "https://images.unsplash.com/photo-1639322537228-f710d846310a?auto=format&fit=crop&w=1200&q=80",
    "ledger": "https://images.unsplash.com/photo-1487058792275-0ad4aaf24ca7?auto=format&fit=crop&w=1200&q=80",
}

# --------------------------------------------------------------------------- #
#  PAGES                                                                        #
# --------------------------------------------------------------------------- #
PAGES = []  # (key, parent_key|None, owner_key, title, icon, cover|None, properties, blocks)

def page(key, parent, owner, title, icon, cover, blocks, props=None):
    PAGES.append((key, parent, owner, title, icon, cover, props or [], blocks))

# ---- 🧭 Mission Control ------------------------------------------------------
page("mission-control", None, "helena", "🧭 Mission Control", "🧭", COVER["ops"], [
    h1("Binocle Intelligence Agency — Mission Control"),
    callout("🎯", "**Welcome to the org workspace.** Everything the agency runs on lives here: "
                  "the Handbook, live Case Wikis, the Evidence Gallery and the Analyst Notebooks. "
                  "If you are new, start with the Onboarding Checklist in the 📖 Agency Handbook."),
    columns(
        (1, [h3("📖 Handbook"), p("SOPs, custody protocol, clearance & ABAC policy, onboarding.")]),
        (1, [h3("🗂️ Case Wikis"), p("One wiki per active operation, wired to the live case tables.")]),
        (1, [h3("🖼️ Evidence"), p("Galleries per evidence kind plus the Q2 custody audit.")]),
    ),
    divider(),
    h2("Agency at a glance"),
    table(["Plane", "Holdings", "Source of truth"],
          [["Cases", "40 operations (BIA-202x-NNN)", "live `cases` table"],
           ["Subjects", "60 persons of interest", "live `subjects` table"],
           ["Evidence", "120 sealed items", "live `evidence` table"],
           ["Transactions", "150 monitored movements", "live `transactions` table"],
           ["Communications", "200 intercept summaries", "live `communications` table"]]),
    callout("⚠️", "Clearance applies everywhere: what you see in the live tables below is already "
                  "filtered and masked by your role. See **Clearance Levels & Access Policy**."),
    h2("Live case board"),
    p("The board below is the live `cases` table — not a copy. Edits here write back to the "
      "operational database and broadcast to everyone watching."),
    live_db("cases"),
    divider(),
    quote("We connect dots that were never supposed to meet. — H. Voss, Director"),
])

# ---- 📖 Agency Handbook ------------------------------------------------------
page("handbook", None, "helena", "📖 Agency Handbook", "📖", COVER["handbook"], [
    h1("Agency Handbook"),
    callout("📘", "The Handbook is the operating contract of the Binocle Intelligence Agency. "
                  "Every section is binding policy unless marked as guidance."),
    h2("Contents"),
    bullet("Standard Operating Procedures — how casework actually flows."),
    bullet("Evidence Custody Protocol — sealing, logging, verification."),
    bullet("Clearance Levels & Access Policy — who sees what, and why."),
    bullet("Onboarding Checklist — your first week, step by step."),
    bullet("Field Operations Guide — surveillance & approach discipline."),
    bullet("Report Writing Standards — language that survives a courtroom."),
    divider(),
    callout("✅", "Policy questions go to #general; case-specific questions to #case-ops."),
])

page("sop", "handbook", "helena", "Standard Operating Procedures", "📋", None, [
    h1("Standard Operating Procedures"),
    callout("📌", "**Scope** — every BIA operation, from intake to archive. Deviations require "
                  "sign-off from the Director or Deputy Director and a note on the case wiki."),
    h2("1 · Case lifecycle"),
    numbered("**Intake** — a lead or client referral is logged in `leads` with source and credibility."),
    numbered("**Open** — a case manager assigns a code (BIA-YYYY-NNN), a lead investigator and a budget."),
    numbered("**Investigate** — field, surveillance, forensics and analysis work the case in parallel; "
             "every artefact lands in the live tables, never in private files.", kids=[
        bullet("Field agents file contact reports within 12 hours."),
        bullet("Analysts keep working notes in their Analyst Notebook."),
    ]),
    numbered("**Review** — legal + the case manager check the evidentiary chain before any referral."),
    numbered("**Close / Cold** — outcomes are recorded in `reports`; cold cases keep their assignments."),
    h2("2 · Communication discipline"),
    bullet("Operational chatter stays in #case-ops; analysis threads in #intel-analysts."),
    bullet("Never paste raw intercept content into chat — link the `communications` row instead."),
    bullet("War Room (video) is for live coordination only; decisions made there are minuted "
           "on the case wiki within 24 hours."),
    callout("⚠️", "**Warning** — discussing privileged material (lawyer–client intercepts) outside "
                  "the legal review loop is a custody breach. Isabel Romero must clear it first."),
    h2("3 · Data hygiene"),
    bullet("The live tables are the single source of truth — wiki pages cite ids (EV-0084, BIA-2026-001)."),
    bullet("Amounts, account refs and SSNs are masked per clearance; do not transcribe unmasked values."),
    bullet("Use the watchlist memo before adding a new counterparty alias."),
    callout("❗", "**Hard rule** — no operational data leaves the workspace. Exports require the "
                  "Director's written approval and an entry in the custody audit."),
    divider(),
    quote("Slow is smooth, smooth is fast."),
])

page("custody", "handbook", "hannah", "Evidence Custody Protocol", "🔐", None, [
    h1("Evidence Custody Protocol"),
    callout("🔐", "**Why this exists** — a single broken custody link voids an exhibit. The protocol "
                  "below is the minimum; forensics may add stricter handling per item."),
    h2("Custody chain — the five mandatory entries"),
    numbered("**Collection** — collecting officer, timestamp, location id, method (e.g. “records request”)."),
    numbered("**Sealing** — tamper-evident bag id + the BIA-EV-NNNN label; photograph the seal."),
    numbered("**Transport** — courier + route; hand-offs are logged at both ends."),
    numbered("**Storage** — vault location id from the `locations` table; access list snapshot."),
    numbered("**Verification** — integrity check (hash for digital media, seal audit for physical)."),
    h2("Verification states"),
    table(["State", "Meaning", "Action"],
          [["verified ✅", "seal/hash intact at last audit", "none"],
           ["pending 🕐", "new item, first audit not run", "audit within 72h"],
           ["failed ❌", "seal broken or hash mismatch", "quarantine + forensic review + memo to legal"]]),
    callout("❌", "**Live alert** — EV-0055 (surveillance tape, Operation Red Meridian) failed its last "
                  "integrity verification. It is quarantined; see the Custody Audit — Q2 page."),
    h2("Digital media specifics"),
    bullet("Image first, analyse the copy — originals are write-blocked and vaulted."),
    bullet("Hashes (SHA-256) recorded at collection and at every transfer."),
    bullet("Phone dumps and hard drives get a forensics ticket before any analyst touches them."),
    toggle("▸ Common custody mistakes (read this twice)", [
        bullet("Logging transport but not the hand-off at the receiving end."),
        bullet("Re-sealing with a new bag id without cross-referencing the old one."),
        bullet("Analysts working on originals because “the copy was slow”."),
        callout("⚠️", "Every one of these has cost an agency a case. Not ours, not again."),
    ]),
    divider(),
    quote("Custody is a chain. Chains have links. Links have names on them. — H. Weiss"),
])

page("clearance", "handbook", "marcus", "Clearance Levels & Access Policy", "🛂", None, [
    h1("Clearance Levels & Access Policy"),
    callout("🛂", "**Model** — attribute-based access control (ABAC). A decision combines your "
                  "**role**, **department**, **clearance level (1–5)** and **region** against the "
                  "sensitivity of each table, row and column."),
    h2("Clearance ladder"),
    table(["Level", "Who", "What it unlocks"],
          [["5", "Director, Deputy Director", "everything, including budgets and informant identities"],
           ["4", "Case managers, senior investigators, IT admin", "full case rows, unmasked transactions"],
           ["3", "Analysts, forensics, legal, finance", "case rows, masked amounts/SSNs, no informants"],
           ["2", "Field agents, surveillance", "own-case rows, location + vehicle data, no financials"]]),
    h2("Column masks in practice"),
    bullet("**Analysts (clearance 3)** see transaction *patterns* but redacted exact amounts above "
           "the reporting threshold — enough to flag structuring, not enough to leak balances."),
    bullet("**Field agents** see subjects and locations for their assignments; account refs render as `••••`."),
    bullet("**Legal** sees privileged communications; nobody else does, including command, until released."),
    bullet("**Finance** sees aggregates (sums, counts by counterparty) without per-row drill-down."),
    callout("💡", "If a cell renders as `••••` or a row you expect is missing, that is the policy "
                  "engine working — not a bug. Request elevation via your case manager."),
    h2("Row scoping"),
    numbered("Region first — APAC staff see APAC-tagged rows plus global rows."),
    numbered("Department second — surveillance sees `communications` and `vehicles`, not `transactions`."),
    numbered("Assignment last — clearance 2 requires an `assignments` row linking you to the case."),
    callout("⚠️", "Sharing a screenshot of data the recipient could not query themselves is treated "
                  "as an access violation. The mask follows the data, not the pixels."),
    divider(),
    quote("Need-to-know is not gatekeeping; it is how we protect sources. — M. Reed"),
])

page("onboarding", "handbook", "sofia", "Onboarding Checklist", "✅", None, [
    h1("Onboarding Checklist"),
    callout("👋", "Welcome aboard. Work through this top to bottom during week one. Your buddy is "
                  "your department's senior — ping them in #general if anything is unclear."),
    h2("Day 1 — access"),
    todo("Log in to the workspace and set your profile (photo, role, region).", True),
    todo("Verify your clearance level renders correctly on the Mission Control live board.", True),
    todo("Join your channels: #general plus your department channel.", True),
    todo("Read the Standard Operating Procedures end to end.", False),
    h2("Week 1 — context"),
    todo("Read the Clearance Levels & Access Policy and confirm your masks with IT (Maya).", False),
    todo("Shadow one custody hand-off with forensics (Hannah or Omar).", False),
    todo("Read the case wiki of every operation you are assigned to.", False),
    todo("Add yourself to the on-call rota if you are field or surveillance.", False),
    h2("Before your first solo task"),
    todo("Pass the custody quiz (forensics runs it Fridays).", False),
    todo("File a practice contact report and have it reviewed by your case manager.", False),
    todo("Confirm you can reach the War Room video channel from your kit.", False),
    callout("✅", "When every box above is ticked, your case manager flips your status to operational."),
])

page("fieldguide", "handbook", "jack", "Field Operations Guide", "🕶️", None, [
    h1("Field Operations Guide"),
    callout("🕶️", "Guidance, not law — but deviating without telling your case manager *is* a "
                  "violation of the SOP. Stay boring, stay invisible."),
    h2("Surveillance discipline"),
    bullet("Two-person minimum on static observation; rotate eyes every 40 minutes."),
    bullet("Log plate sightings immediately — the second-location match on Operation Red Meridian "
           "came from a 30-second log entry (lead L-0079)."),
    bullet("Radio checks on the quarter hour; missed check = abort criteria after 30 minutes."),
    toggle("▸ Scenario: subject meets unknown party (like the marina contact, L-0022)", [
        numbered("Do not approach. Photograph context, not faces, if exposure risk is high."),
        numbered("Log time, location id, and a one-line description in `leads`."),
        numbered("Tag the case analyst in #case-ops within the hour."),
    ]),
    toggle("▸ Scenario: cash courier pattern (Friday runs, L-0032)", [
        numbered("Confirm the pattern across three cycles before requesting an intercept."),
        numbered("Coordinate with finance (Robert) so the amounts line up with the txn record."),
        numbered("Never seize on pattern alone — wait for the warrant package from legal."),
    ]),
    h2("Approach & contact"),
    bullet("Covers are issued by operations; never improvise an affiliation."),
    bullet("If burned, break contact, signal in #field with the word **SUNSET**, and head to the fallback."),
    callout("⚠️", "A burned cover is recoverable. A burned informant is not."),
    divider(),
    quote("The best surveillance log reads like the most boring novel ever written. — J. Sullivan"),
])

page("reporting", "handbook", "isabel", "Report Writing Standards", "⚖️", None, [
    h1("Report Writing Standards"),
    callout("⚖️", "Reports outlive operations. Write every sentence as if opposing counsel will "
                  "read it aloud, slowly, to a jury."),
    h2("Structure"),
    numbered("**Header** — case code, report id, author, date, classification."),
    numbered("**Summary** — three sentences max; findings, not narrative."),
    numbered("**Facts** — numbered observations, each citing its source row (EV/TXN/COMM id)."),
    numbered("**Analysis** — clearly separated from facts; hedge with calibrated language."),
    numbered("**Annexes** — exhibit list with custody references."),
    h2("Language rules"),
    table(["Write", "Not", "Why"],
          [["“consistent with”", "“proves”", "analysis is inference, not verdict"],
           ["“subject stated”", "“subject admitted”", "characterisation is the court's job"],
           ["“EV-0084 (ledger)”", "“the ledger we found”", "exhibits are cited by id"],
           ["“assessed as likely”", "“obviously”", "calibrated confidence survives cross"]]),
    callout("❗", "Privileged material (lawyer–client comms) is never quoted in a report body — "
                  "reference the row id and route through legal review."),
    quote("If it is not in the record, it did not happen."),
])

# ---- 🗂️ Case Wikis -----------------------------------------------------------
page("cases-root", None, "marcus", "🗂️ Case Wikis", "🗂️", COVER["cases"], [
    h1("Case Wikis"),
    callout("🗂️", "One wiki per operation. The wiki is the *narrative* layer — context, hypotheses, "
                  "decisions — while the live tables stay the factual record. Keep ids in every claim."),
    h2("Live case register"),
    p("Embedded view of the live `cases` table. Open an operation's wiki below for the working notes."),
    live_db("cases"),
    h2("Featured operations"),
    bullet("Operation Nightfall (BIA-2026-001) — crypto-mixer laundering, our newest open case."),
    bullet("Operation Cobalt Ledger (BIA-2025-002) — closed; freeport vault concealment, full retro."),
    bullet("Operation Red Meridian (BIA-2025-008) — in review; art-market fraud, custody alert."),
    bullet("Operation Quiet Storm (BIA-2025-012) — analysis; procurement fraud via freeport."),
    bullet("Operation Ash Garden (BIA-2025-014) — active surveillance; shell-company laundering."),
    bullet("Operation Broken Compass (BIA-2025-016) — open; asset concealment through mixers."),
])

page("case-nightfall", "cases-root", "marcus", "Operation Nightfall — BIA-2026-001", "🌒", COVER["night"], [
    h1("Operation Nightfall"),
    callout("🌒", "**BIA-2026-001 · OPEN · HIGH** — suspected money laundering through crypto "
                  "mixers. Lead investigator: Marcus Reed. Primary subject: **Beatriz Albrecht** "
                  "(logistics manager, IT national, risk: critical).", level=3),
    h2("Working hypothesis"),
    p("Albrecht's logistics firm books phantom freight, settles in USDT through **Goldquay Exchange**, "
      "and recycles the proceeds via mixer hops before they resurface as 'consulting income' from "
      "**Westport Capital SA**. The ledger seized in March (EV-0084) shows paired entries that match "
      "the flagged transaction pattern Erik documented in his notebook."),
    h2("Evidence on hand"),
    bullet("**EV-0084** — ledger, recovered during surveillance op (Amara Diallo), custody log 4 entries, verified."),
    bullet("**EV-0086** — hard drive, surveillance op (Hannah Weiss), custody log 5 entries, verified."),
    bullet("**EV-0087** — contract, surveillance op (Jack Sullivan), custody log 4 entries, verified."),
    bullet("**EV-0098** — hard drive, site visit (Viktor Antonov), custody log 4 entries, verified."),
    h2("Intercept of note"),
    quote("Payment confirmation — amount matches txn pattern. (COMM-0085, in person, unregistered "
          "SIM, classified: incriminating)"),
    callout("⚠️", "COMM-0139 mentions a freeport contact *by first name* and is classified privileged — "
                  "route any use through Isabel before it appears in a report."),
    h2("Lead tracker"),
    toggle("▸ L-0003 — cash courier on Fridays (wiretap, medium) — DEAD END", [
        p("Three observation cycles produced nothing; the courier pattern belongs to a "
          "legitimate cash-intensive business next door. Closed 14 May, do not re-open without "
          "new signal."),
    ]),
    toggle("▸ Mixer exit clustering (analysis, working)", [
        p("Erik's clustering of mixer exits puts ~64% of the traced value re-entering through "
          "two Goldquay sub-accounts. Need the exchange's KYC packet — legal drafting the request."),
        todo("Subpoena package for Goldquay KYC (legal)", False),
        todo("Cross-reference EV-0086 wallet artefacts with the exit cluster", False),
    ]),
    h2("Linked subjects (live)"),
    live_db("subjects"),
    divider(),
    callout("✅", "Next sync: War Room, Thursday 09:00 — bring the Goldquay timeline."),
], props=relation([uid("page:nb-erik"), uid("page:nb-watchlist")]))

page("case-cobalt", "cases-root", "nadia", "Operation Cobalt Ledger — BIA-2025-002", "🧊", COVER["vault"], [
    h1("Operation Cobalt Ledger"),
    callout("🧊", "**BIA-2025-002 · CLOSED · CRITICAL** — asset concealment via a freeport vault. "
                  "Lead investigator: Nadia Petrova. This wiki is the closing retrospective.", level=3),
    h2("What happened"),
    p("An import/export broker (**Lena Esposito**, “Doc”) and an art dealer (**Mei Wagner**, “Brick”) "
      "moved undeclared assets into a freeport vault using shipping manifests that understated crate "
      "contents. Their lawyer, **Dmitri Iglesias**, structured ownership through nominee paper. The "
      "manifest seized at the source meeting (EV-0026) broke the case open."),
    h2("How it closed"),
    numbered("EV-0026 (shipping manifest) showed weight/insurance mismatches across nine shipments."),
    numbered("The confirmed wiretap lead L-0032 — the Friday cash courier — tied Esposito to the vault custodian."),
    numbered("EV-0094 (phone dump) recovered deleted coordination messages; EV-0100 (contract) "
             "established the nominee structure."),
    numbered("Referral accepted; convictions on 4 of 5 counts. Vault contents repatriated."),
    h2("Intercept that mattered"),
    quote("Arranged meeting; location referenced obliquely. (COMM-0111, in person, Westport Capital SA "
          "counterparty — the 'oblique' location was the freeport mezzanine.)"),
    h2("Lessons learned"),
    columns(
        (1, [h3("✅ What worked"),
             bullet("Manifest forensics before subject interviews — they never saw it coming."),
             bullet("Custody discipline: all 3 exhibits survived defence challenges."),
             bullet("Joint finance/field review of the courier pattern.")]),
        (1, [h3("⚠️ What we'd change"),
             bullet("Earlier legal review — the nominee paper took weeks we did not have."),
             bullet("Westport Capital SA appears again in Nightfall: open a standing watchlist entry."),
             bullet("Vault CCTV request went out late; footage cycle had purged 11 days.")]),
    ),
    divider(),
    quote("Closed cases teach more than open ones, if you let them. — N. Petrova"),
], props=relation([uid("page:case-nightfall"), uid("page:nb-watchlist")]))

page("case-redmeridian", "cases-root", "marcus", "Operation Red Meridian — BIA-2025-008", "🧭", COVER["meridian"], [
    h1("Operation Red Meridian"),
    callout("🧭", "**BIA-2025-008 · REVIEW · CRITICAL** — art-market fraud via trade mis-invoicing. "
                  "Lead investigator: Marcus Reed. Status: evidentiary review before referral.", level=3),
    h2("Theory of the case"),
    p("Canvas valuations are inflated on export and deflated on import, with the spread settled "
      "offshore. The structuring leads (L-0039, L-0058) show repeated movements just under the "
      "reporting threshold — textbook smurfing against the art invoices."),
    h2("Lead tracker"),
    toggle("▸ L-0022 — subject met unknown male at the marina (open source, confirmed) — ESCALATED", [
        p("Surveillance (Grace) confirmed a second meeting at the same berth. Counterparty "
          "tentatively matched to a Kestrel Marine Ltd charter manager."),
    ]),
    toggle("▸ L-0039 — structuring under the reporting threshold (open source, high) — DEAD END", [
        p("The sub-threshold pattern traced to an unrelated remittance corridor. Useful "
          "methodology, wrong subject. Filed for the analyst playbook."),
    ]),
    toggle("▸ L-0048 — cash courier run on Fridays (bank alert, confirmed) — ESCALATED", [
        p("Bank alert corroborated by two field cycles. Warrant package in legal review."),
    ]),
    toggle("▸ L-0079 — vehicle plate matched at second location (anonymous tip) — CORROBORATED", [
        p("Plate logged by Tom at location L-21 matched Viktor's earlier sighting. The vehicle "
          "links our subject to the freight forwarder's yard."),
    ]),
    h2("Custody alert"),
    callout("❌", "**EV-0055 (surveillance tape) failed integrity verification.** Quarantined; "
                  "forensic review running. The referral package must NOT cite EV-0055 until "
                  "Hannah clears it — see Custody Audit — Q2."),
    h2("Evidence (clean)"),
    bullet("**EV-0017** — shipping manifest (Pierre Moreau), verified."),
    bullet("**EV-0039** — hard drive (Grace Liu), verified."),
    h2("Live leads register"),
    live_db("leads"),
    divider(),
    quote("Arranged meeting; location referenced obliquely. (COMM-0044, phone, unregistered SIM)"),
], props=relation([uid("page:gal-custody"), uid("page:nb-priya")]))

page("case-quietstorm", "cases-root", "pierre", "Operation Quiet Storm — BIA-2025-012", "⛈️", COVER["storm"], [
    h1("Operation Quiet Storm"),
    callout("⛈️", "**BIA-2025-012 · ANALYSIS · CRITICAL** — procurement fraud routed through a "
                  "freeport vault. Lead investigator: Pierre Moreau. Subject of record: **Zofia "
                  "Haddad** (casino host, CH).", level=3),
    h2("Where the analysis stands"),
    p("Procurement awards cluster around three vendors that share a registered agent. Settlement "
      "flows pass **Cygnus Consulting GmbH** and **Aurelia Trade FZE** before landing as casino "
      "credit — which is where Haddad's host ledger comes in (EV-0071, bank statement, verified)."),
    h2("Intercepts of note"),
    quote("Discussed 'paperwork' for upcoming shipment. (COMM-0077, in person, Goldquay Exchange "
          "counterparty — privileged, legal hold)"),
    quote("Arranged meeting; location referenced obliquely. (COMM-0118, phone, unknown number — "
          "classified incriminating)"),
    callout("💡", "The 'paperwork' phrasing repeats across Quiet Storm and Ash Garden intercepts. "
                  "Priya is testing whether it is corridor slang or the same fixer."),
    h2("Evidence on hand"),
    bullet("**EV-0029** — surveillance tape (Hannah Weiss), verified."),
    bullet("**EV-0041** — surveillance tape (Leila Haddad), verified."),
    bullet("**EV-0071** — bank statement (Viktor Antonov), custody log 6 entries, verified."),
    h2("Open analysis tasks"),
    todo("Map the registered-agent overlap across the three vendors (Carlos)", False),
    todo("Reconcile casino credit issuance vs. EV-0071 statement lines (Robert + Erik)", False),
    todo("Request freeport access logs for the award weeks (legal)", False),
    divider(),
    quote("Fraud at this layer is just logistics with better stationery. — P. Moreau"),
], props=relation([uid("page:nb-carlos"), uid("page:nb-priya")]))

page("case-ashgarden", "cases-root", "jack", "Operation Ash Garden — BIA-2025-014", "🌫️", COVER["garden"], [
    h1("Operation Ash Garden"),
    callout("🌫️", "**BIA-2025-014 · ACTIVE SURVEILLANCE · HIGH** — suspected laundering through "
                  "shell companies. Lead investigator: Jack Sullivan. Subject of record: **Beatriz "
                  "Petrov** (lawyer, FR).", level=3),
    callout("⚠️", "**Privilege warning** — the subject is a practising lawyer. COMM-0041 and "
                  "COMM-0045 are classified privileged. Surveillance product must be screened by "
                  "Isabel BEFORE it reaches the analysts. No exceptions."),
    h2("Surveillance posture"),
    bullet("Static observation on the office block: two-person rotation (Grace / Viktor)."),
    bullet("Mobile follow only on pre-cleared routes; subject is counter-surveillance aware."),
    bullet("Friday pattern: subject visits the notary, then the Goldquay storefront (COMM-0045 "
           "travel-plan intercept matches)."),
    h2("Evidence on hand"),
    bullet("**EV-0011** — ledger (Jack Sullivan), custody log 5 entries, verified."),
    bullet("**EV-0051** — burner phone (Maya Kowalski), forensic imaging complete, verified."),
    bullet("**EV-0058** — hard drive (Marcus Reed), forensic imaging complete, verified."),
    bullet("**EV-0076** — surveillance tape (Viktor Antonov), custody log 6 entries, verified."),
    h2("Working notes"),
    toggle("▸ Shell layering pattern (working)", [
        p("Three shells rotate the same nominee director. Incorporation dates precede each "
          "procurement window by 18–24 days. Carlos is checking whether the pattern matches the "
          "Quiet Storm vendors."),
    ]),
    toggle("▸ Burner phone (EV-0051) extraction highlights", [
        bullet("Contact graph: 9 numbers, 7 single-use."),
        bullet("Recurring number resolves to an unregistered SIM — same device family as the "
               "Nightfall COMM-0085 source."),
        callout("🔥", "If the SIM link holds, Ash Garden and Nightfall share a fixer."),
    ]),
    divider(),
    quote("Discussed 'paperwork' for upcoming shipment. (COMM-0041, phone, unregistered SIM — privileged)"),
], props=relation([uid("page:case-nightfall"), uid("page:case-quietstorm")]))

page("case-brokencompass", "cases-root", "tom", "Operation Broken Compass — BIA-2025-016", "🧿", COVER["compass"], [
    h1("Operation Broken Compass"),
    callout("🧿", "**BIA-2025-016 · OPEN · HIGH** — asset concealment through crypto mixers. "
                  "Lead investigator: Tom Becker.", level=3),
    h2("Situation"),
    p("Proceeds from a property flip scheme (**Novum Estates** is the recurring counterparty — see "
      "COMM-0068, classified incriminating) disappear into mixer deposits within 48 hours of each "
      "closing. Exit liquidity surfaces as marine charter payments to **Kestrel Marine Ltd** — the "
      "same charter shop that brushed against Red Meridian's marina lead."),
    h2("Evidence on hand"),
    bullet("**EV-0077** — contract (Grace Liu), verified."),
    bullet("**EV-0101** — document (Jack Sullivan), custody log 5 entries, verified."),
    bullet("**EV-0103** — bank statement (Grace Liu), verified."),
    h2("Intercepts of note"),
    quote("Discussed 'paperwork' for upcoming shipment. (COMM-0068, phone, Novum Estates — incriminating)"),
    quote("Mentioned contact at the freeport by first name. (COMM-0134, sms, Kestrel Marine Ltd)"),
    h2("Open questions"),
    toggle("▸ Is Kestrel Marine a coincidence or a hub?", [
        p("Two operations, one charter company. Priya's counterparty graph ranks Kestrel in the "
          "top decile by cross-case degree. Watchlist entry opened."),
    ]),
    toggle("▸ Mixer exit timing", [
        p("Exits cluster 03:00–05:00 UTC. Either automation or an operator in an eastern "
          "timezone. Erik is correlating with Goldquay's settlement batches."),
    ]),
    todo("Charter manifests subpoena (legal, drafting)", False),
    todo("Cross-case SIM comparison with Ash Garden EV-0051 graph (forensics)", False),
    divider(),
    quote("Follow the boats. Money gets seasick too. — T. Becker"),
], props=relation([uid("page:case-redmeridian"), uid("page:nb-watchlist")]))

# ---- 🖼️ Evidence Gallery ----------------------------------------------------
page("gallery-root", None, "omar", "🖼️ Evidence Gallery", "🖼️", COVER["gallery"], [
    h1("Evidence Gallery"),
    callout("🖼️", "Visual index of the evidence vault, grouped by kind. Cards are sanitised scans — "
                  "the factual record stays in the live `evidence` table below. 120 items under custody."),
    h2("Collections"),
    columns(
        (1, [h3("🏦 Financial Records"), p("Bank statements, ledgers, wire receipts.")]),
        (1, [h3("💾 Digital Forensics"), p("Hard drives, phone dumps, burner phones.")]),
    ),
    columns(
        (1, [h3("🎞️ Surveillance Materials"), p("Tapes and photographs from observation posts.")]),
        (1, [h3("📜 Documents & Contracts"), p("Contracts, manifests, corporate paper.")]),
    ),
    h2("Live evidence register"),
    live_db("evidence"),
    callout("⚠️", "One item is currently quarantined (EV-0055). See Custody Audit — Q2."),
])

page("gal-financial", "gallery-root", "robert", "Financial Records", "🏦", None, [
    h1("Financial Records"),
    callout("🏦", "Bank statements, ledgers and wire receipts. Amounts render masked for clearance "
                  "below 4 — the scans here are sanitised previews."),
    evidence_card("EV-0084 · LEDGER", "Operation Nightfall — paired phantom-freight entries", "#1f3a5f"),
    p("Recovered by Amara Diallo during a surveillance op. The paired entries match Erik's flagged "
      "Goldquay pattern; referenced throughout the Nightfall wiki."),
    evidence_card("EV-0071 · BANK STATEMENT", "Operation Quiet Storm — casino credit reconciliation", "#274060"),
    p("Six custody entries, verified. Statement lines reconcile against casino credit issuance with "
      "a residual the analysts are still chasing."),
    evidence_card("EV-0103 · BANK STATEMENT", "Operation Broken Compass — charter payment trail", "#30506b"),
    p("Collected by Grace Liu. Charter payments to Kestrel Marine Ltd land within 48h of each "
      "property closing."),
    divider(),
    table(["Item", "Case", "State"],
          [["EV-0084 ledger", "BIA-2026-001", "verified ✅"],
           ["EV-0071 bank statement", "BIA-2025-012", "verified ✅"],
           ["EV-0103 bank statement", "BIA-2025-016", "verified ✅"]]),
])

page("gal-digital", "gallery-root", "maya", "Digital Forensics", "💾", None, [
    h1("Digital Forensics"),
    callout("💾", "Imaged media only — originals are write-blocked and vaulted. Every image carries "
                  "a SHA-256 recorded at collection and at each transfer."),
    evidence_card("EV-0086 · HARD DRIVE", "Operation Nightfall — wallet artefacts", "#3b2f5f"),
    p("Imaged by Hannah Weiss. Wallet artefacts feed the mixer exit clustering work."),
    evidence_card("EV-0051 · BURNER PHONE", "Operation Ash Garden — contact graph, 9 numbers", "#46396b"),
    p("Forensic imaging complete (Maya Kowalski). The recurring unregistered SIM may link Ash "
      "Garden to Nightfall's COMM-0085 source."),
    evidence_card("EV-0094 · PHONE DUMP", "Operation Cobalt Ledger — recovered deletions", "#503f73"),
    p("Deleted coordination messages recovered; admitted as exhibit at trial. Case closed."),
    divider(),
    callout("✅", "Imaging queue is clear. New media gets a forensics ticket before any analyst touches it."),
])

page("gal-surveillance", "gallery-root", "viktor", "Surveillance Materials", "🎞️", None, [
    h1("Surveillance Materials"),
    callout("🎞️", "Observation-post product: tapes and photographs. Location ids reference the live "
                  "`locations` table."),
    evidence_card("EV-0076 · SURVEILLANCE TAPE", "Operation Ash Garden — office block static", "#5f2f3a"),
    p("Six custody entries, verified. Covers the Friday notary-then-Goldquay pattern."),
    evidence_card("EV-0029 · SURVEILLANCE TAPE", "Operation Quiet Storm — records request capture", "#6b3946"),
    p("Verified. Paired with EV-0041 for the vendor-meeting timeline."),
    evidence_card("EV-0055 · SURVEILLANCE TAPE", "Operation Red Meridian — QUARANTINED", "#7a2e2e"),
    callout("❌", "EV-0055 failed integrity verification — do not cite until forensics clears it."),
    divider(),
    quote("Film what is there, log what you filmed, touch nothing else. — V. Antonov"),
])

page("gal-documents", "gallery-root", "grace", "Documents & Contracts", "📜", None, [
    h1("Documents & Contracts"),
    callout("📜", "Corporate paper: contracts, manifests, incorporation documents. The mis-invoicing "
                  "cases live and die on these."),
    evidence_card("EV-0026 · SHIPPING MANIFEST", "Operation Cobalt Ledger — the case-breaker", "#2f5f3a"),
    p("Weight/insurance mismatches across nine shipments. The exhibit that closed Cobalt Ledger."),
    evidence_card("EV-0017 · SHIPPING MANIFEST", "Operation Red Meridian — export valuation set", "#396b46"),
    p("Collected by Pierre Moreau. Export valuations feed the inflated-spread model."),
    evidence_card("EV-0087 · CONTRACT", "Operation Nightfall — phantom freight terms", "#3f7350"),
    p("Recovered by Jack Sullivan. Freight terms with no corresponding cargo movements."),
    divider(),
    table(["Item", "Kind", "Case", "State"],
          [["EV-0026", "shipping manifest", "BIA-2025-002", "verified ✅"],
           ["EV-0017", "shipping manifest", "BIA-2025-008", "verified ✅"],
           ["EV-0087", "contract", "BIA-2026-001", "verified ✅"],
           ["EV-0100", "contract", "BIA-2025-002", "verified ✅"]]),
])

page("gal-custody", "gallery-root", "hannah", "Custody Audit — Q2", "🧾", None, [
    h1("Custody Audit — Q2"),
    callout("🧾", "Quarterly verification sweep across the evidence vault. 120 items audited; one "
                  "failure, three pending re-checks."),
    h2("Findings"),
    table(["Exhibit", "Kind", "Case", "Result", "Action"],
          [["EV-0055", "surveillance tape", "BIA-2025-008", "FAILED ❌", "quarantine + forensic review"],
           ["EV-0042", "wire receipt", "BIA-2025-009", "re-verify 🕐", "custody log updated — second check booked"],
           ["EV-0011", "ledger", "BIA-2025-014", "verified ✅", "none"],
           ["EV-0084", "ledger", "BIA-2026-001", "verified ✅", "none"],
           ["EV-0026", "shipping manifest", "BIA-2025-002", "verified ✅", "archived (case closed)"]]),
    h2("EV-0055 incident"),
    numbered("Seal audit found the outer bag id re-logged without cross-reference to the original."),
    numbered("Tape itself shows no splice artefacts on first pass; deep verification running."),
    numbered("Until cleared, Red Meridian's referral package excludes EV-0055 (Marcus notified)."),
    callout("⚠️", "Root cause was a transport hand-off logged at origin only — exactly the mistake "
                  "called out in the Evidence Custody Protocol. Refresher session scheduled."),
    todo("Deep verification of EV-0055 (forensics)", False),
    todo("Re-verify EV-0042 custody log", False),
    todo("Custody refresher for transport couriers", False),
])

# ---- 📓 Analyst Notebooks ----------------------------------------------------
page("notebooks-root", None, "erik", "📓 Analyst Notebooks", "📓", COVER["notebooks"], [
    h1("Analyst Notebooks"),
    callout("📓", "Working notes, one notebook per analyst. Notebooks are *thinking space* — "
                  "hypotheses live here until they earn a place on a case wiki with an id attached."),
    bullet("Erik Johansson — transaction patterns, structuring, mixer exits."),
    bullet("Priya Sharma — counterparty graph, cross-case entity resolution."),
    bullet("Carlos Mendez — corridors (hawala, freight), NA region focus."),
    bullet("Watchlist — Counterparties: the shared memo the three keep current."),
])

page("nb-erik", "notebooks-root", "erik", "Erik Johansson — Working Notes", "🧮", None, [
    h1("Working Notes — Erik Johansson"),
    callout("🧮", "Analysis dept · clearance 3 · EU. Amounts above threshold render masked on my "
                  "view; patterns below are computed on the masked series (which is the point)."),
    h2("TXN pattern: structuring under 10k via Goldquay"),
    p("Recurring movements sit just under the reporting threshold: TXN-0010 (9,769.57 EUR, wire, "
      "Westport Capital SA), TXN-0002 (5,145.88 USDT, cash deposit, Goldquay Exchange), TXN-0014 "
      "(6,064.96 USDT, crypto, Goldquay). Sub-threshold density against Goldquay is 3.1× the "
      "corridor baseline — that is not noise."),
    table(["TXN", "Amount", "Method", "Counterparty", "Flag"],
          [["TXN-0010", "9,769.57 EUR", "wire", "Westport Capital SA", "🚩"],
           ["TXN-0002", "5,145.88 USDT", "cash deposit", "Goldquay Exchange", "🚩"],
           ["TXN-0014", "6,064.96 USDT", "crypto", "Goldquay Exchange", "🚩"],
           ["TXN-0009", "4,974.82 AED", "crypto", "Westport Capital SA", "🚩"]]),
    callout("🔥", "Outlier: **TXN-0016 — 306,454.56 EUR via hawala to Goldquay Exchange.** A six-figure "
                  "hawala movement to an *exchange* breaks the structuring profile entirely. Either a "
                  "settlement between operators or someone got sloppy. Escalated to Marcus."),
    h2("Mixer exit timing (Broken Compass support)"),
    bullet("Exit cluster 03:00–05:00 UTC correlates with Goldquay settlement batches at 0.78."),
    bullet("If automation, expect the same offsets next cycle — watch booked for Thursday."),
    toggle("▸ Method note: working on masked series", [
        p("Clearance 3 masks exact amounts above threshold, so I bucket to 500-unit bands and "
          "test density, not values. Pattern conclusions survive the mask; totals go to Robert "
          "for the clearance-4 reconciliation."),
    ]),
    h2("Live transactions (my masked view)"),
    live_db("transactions"),
    todo("Thursday: re-run exit-cluster correlation after Goldquay batch", False),
    todo("Hand TXN-0016 memo to Marcus before War Room", True),
], props=relation([uid("page:case-nightfall"), uid("page:case-brokencompass")]))

page("nb-priya", "notebooks-root", "priya", "Priya Sharma — Working Notes", "🕸️", None, [
    h1("Working Notes — Priya Sharma"),
    callout("🕸️", "Analysis dept · clearance 3 · APAC. Entity resolution across cases — who is "
                  "actually the same node wearing different paperwork."),
    h2("Counterparty graph — cross-case degree"),
    p("Ranking counterparties by how many distinct operations they brush against. Anything ≥3 is "
      "no longer a coincidence; it is infrastructure."),
    table(["Counterparty", "Cases touched", "Degree", "Note"],
          [["Goldquay Exchange", "Nightfall, Ash Garden, Broken Compass, Quiet Storm", "4", "settlement hub"],
           ["Westport Capital SA", "Nightfall, Cobalt Ledger (closed)", "2+", "re-offender — standing watch"],
           ["Kestrel Marine Ltd", "Red Meridian, Broken Compass", "2", "charter shop, marina link"],
           ["Aurelia Trade FZE", "Quiet Storm", "1", "registered-agent overlap pending"],
           ["Novum Estates", "Broken Compass", "1", "property-flip counterpart"]]),
    callout("💡", "The 'paperwork' phrasing in COMM-0077 (Quiet Storm) and COMM-0041 (Ash Garden) "
                  "plus the shared unregistered-SIM device family suggests one fixer servicing "
                  "multiple rings. Naming the node FIXER-01 until we have better."),
    h2("Entity resolution queue"),
    todo("Merge candidate: 'Halcyon' alias appears on two different subjects (S-0003, S-0009) — "
         "true duplicate or alias collision?", False),
    todo("Confirm Kestrel charter manager identity from Grace's marina log (L-0022)", False),
    todo("Aurelia ↔ Cygnus registered-agent comparison (with Carlos)", False),
    toggle("▸ Why alias collisions matter", [
        p("Two subjects sharing the alias “Halcyon” will silently merge in any naive graph. Keys "
          "must be (subject_id), never (alias) — the dashboard join was quietly wrong until 02 June."),
    ]),
    divider(),
    quote("A network is just a list of people who answer the same phone. — P. Sharma"),
], props=relation([uid("page:nb-watchlist"), uid("page:case-quietstorm")]))

page("nb-carlos", "notebooks-root", "carlos", "Carlos Mendez — Working Notes", "🚢", None, [
    h1("Working Notes — Carlos Mendez"),
    callout("🚢", "Analysis dept · clearance 3 · NA. Corridors: hawala, freight, anything that moves "
                  "value without moving paperwork."),
    h2("Hawala corridor analysis"),
    p("Hawala-method transactions cluster on two corridors. The NA leg consistently routes via "
      "**Pelican Freight LLC** (e.g. TXN-0013, 6,175.07 USDT, wire) — freight invoices act as the "
      "settlement memo between hawaladars. The EU leg is where TXN-0016's six-figure movement "
      "(Erik's outlier) crossed."),
    bullet("Pattern: freight invoice issued → hawala settlement within 72h → invoice cancelled or "
           "credited the following week."),
    bullet("Cancellation rate at Pelican: 31% of invoices vs. 4% industry norm."),
    bullet("Sable Trust (BVI) takes the residuals: TXN-0024 (76,102.38 EUR, invoice method) fits "
           "the residual profile exactly."),
    h2("Shell incorporation timing (Ash Garden assist)"),
    p("Jack's three shells incorporate 18–24 days before each procurement window. Quiet Storm's "
      "vendors show 19, 21 and 23-day offsets. Same playbook, possibly the same formation agent — "
      "checking the registered-agent overlap with Priya."),
    toggle("▸ Working query (masked view)", [
        p("Group transactions by method × counterparty, flag where hawala share exceeds 20% and "
          "the counterparty also appears on a freight manifest. Three hits: Pelican, Kestrel, and "
          "one new name held back until verified."),
    ]),
    callout("⚠️", "Clearance note: I cannot see informant identities behind the bank alerts — if a "
                  "lead needs source context, it goes through Sofia."),
    todo("Registered-agent overlap memo with Priya (due Friday)", False),
    todo("Pull Pelican cancellation ledger for Q1 (records request drafted)", False),
    divider(),
    quote("Paper doesn't move money. People move money; paper apologises for it. — C. Mendez"),
], props=relation([uid("page:case-quietstorm"), uid("page:case-ashgarden")]))

page("nb-watchlist", "notebooks-root", "priya", "Watchlist — Counterparties (Joint Memo)", "👁️", None, [
    h1("Watchlist — Counterparties"),
    callout("👁️", "Joint memo (Erik · Priya · Carlos). A counterparty enters the watchlist on two "
                  "independent signals; it leaves only by case closure or proven innocence."),
    table(["Entity", "Signals", "Watch level", "Owner"],
          [["Goldquay Exchange", "structuring density, mixer exit correlation, 4-case degree", "🔴 high", "Erik"],
           ["Westport Capital SA", "Cobalt Ledger conviction record, Nightfall recurrence", "🔴 high", "Priya"],
           ["Kestrel Marine Ltd", "marina lead L-0022, Broken Compass charter payments", "🟠 elevated", "Carlos"],
           ["Pelican Freight LLC", "31% invoice cancellation, hawala settlement memo pattern", "🟠 elevated", "Carlos"],
           ["Sable Trust (BVI)", "residual sink, TXN-0024 profile", "🟡 monitor", "Erik"],
           ["Aurelia Trade FZE", "Quiet Storm settlement hop", "🟡 monitor", "Priya"],
           ["Cygnus Consulting GmbH", "TXN-0018 (381,881.49 EUR cash deposit), vendor overlap", "🟠 elevated", "Priya"]]),
    callout("❗", "Adding an entity? Two signals, written down, with ids. Gut feelings go in your own "
                  "notebook until they grow up."),
    h2("Recent changes"),
    bullet("Kestrel Marine Ltd raised to elevated after the Broken Compass charter trail (08 Jun)."),
    bullet("Cygnus added after the TXN-0018 cash deposit anomaly cleared de-duplication (05 Jun)."),
    bullet("FIXER-01 (unresolved entity) tracked separately until identity resolution lands."),
], props=relation([uid("page:nb-erik"), uid("page:nb-priya"), uid("page:nb-carlos")]))

# --------------------------------------------------------------------------- #
#  SQL helpers                                                                  #
# --------------------------------------------------------------------------- #
def b64(obj):
    return base64.b64encode(json.dumps(obj, ensure_ascii=False).encode("utf-8")).decode()

def jcol(obj):
    return f"convert_from(decode('{b64(obj)}','base64'),'utf8')::jsonb"

def sqlstr(s):
    return "'" + s.replace("'", "''") + "'"

# --------------------------------------------------------------------------- #
#  Emit seed_agency_wiki.sql                                                    #
# --------------------------------------------------------------------------- #
wiki_lines = [
    "-- Generated by tools/seeds/seed_agency_wiki.py — idempotent (fixed uuid5 ids,",
    "-- ON CONFLICT (id) DO UPDATE refreshes content). Safe to re-run.",
    "BEGIN;",
]
# created_at offsets keep sidebar ordering stable: roots oldest, children in order.
for i, (key, parent, owner, title, icon, cover, props, blocks) in enumerate(PAGES):
    pid = uid(f"page:{key}")
    parent_sql = f"'{uid('page:' + parent)}'" if parent else "NULL"
    cover_sql = sqlstr(cover) if cover else "NULL"
    created = f"now() - interval '{30 - i} days'"
    wiki_lines.append(
        "INSERT INTO public.osionos_pages "
        "(id, workspace_id, parent_page_id, owner_id, title, icon, cover, surface, visibility, "
        "collaborators, properties, content, created_at, updated_at) VALUES ("
        f"'{pid}', '{WS}', {parent_sql}, '{P(owner)}', {sqlstr(title)}, {sqlstr(icon)}, {cover_sql}, "
        f"NULL, 'shared', '[]'::jsonb, {jcol(props)}, {jcol(blocks)}, {created}, now()) "
        "ON CONFLICT (id) DO UPDATE SET parent_page_id=EXCLUDED.parent_page_id, "
        "owner_id=EXCLUDED.owner_id, title=EXCLUDED.title, icon=EXCLUDED.icon, "
        "cover=EXCLUDED.cover, visibility=EXCLUDED.visibility, properties=EXCLUDED.properties, "
        "content=EXCLUDED.content, archived_at=NULL, updated_at=now();")
wiki_lines.append("COMMIT;")

wiki_out = os.path.join(HERE, "seed_agency_wiki.sql")
with open(wiki_out, "w") as fh:
    fh.write("\n".join(wiki_lines) + "\n")

# --------------------------------------------------------------------------- #
#  CHAT — channels, members, messages, reactions                                #
# --------------------------------------------------------------------------- #
rng = random.Random(20260610)

ALL = list(PEOPLE.keys())
CH = {
    "general": dict(name="general", topic="Agency-wide announcements & day-to-day",
                    kind="text", private=False, created_by="helena", members=ALL),
    "case-ops": dict(name="case-ops", topic="Operational coordination across live cases",
                     kind="text", private=False, created_by="marcus",
                     members=["helena", "marcus", "sofia", "david", "yuki", "pierre", "amara",
                              "jack", "nadia", "tom", "leila"]),
    "intel-analysts": dict(name="intel-analysts", topic="Analysis threads — patterns, graphs, dashboards",
                           kind="text", private=False, created_by="erik",
                           members=["erik", "priya", "carlos", "helena", "marcus"]),
    "field": dict(name="field", topic="Field & surveillance — rotations, sightings, logistics",
                  kind="text", private=False, created_by="jack",
                  members=["jack", "nadia", "tom", "leila", "grace", "viktor", "sofia", "david"]),
    "war-room": dict(name="War Room", topic="Live command coordination (video)",
                     kind="video", private=True, created_by="helena",
                     members=["helena", "marcus", "sofia", "david"]),
}
DMS = [  # (key, a, b)
    ("dm-erik-priya", "erik", "priya"),
    ("dm-marcus-sofia", "marcus", "sofia"),
    ("dm-jack-grace", "jack", "grace"),
    ("dm-helena-marcus", "helena", "marcus"),
]

def dm_key(a, b):
    lo, hi = sorted([P(a), P(b)])
    return f"dm:{lo}:{hi}"

# ---- message threads: (channel, [(author, text), ...]) ----------------------
THREADS = []
def T(channel, *msgs):
    THREADS.append((channel, list(msgs)))

# ======================= #general (≈48) =======================
T("general",
  ("helena", "Welcome to the Binocle org workspace, everyone. The 📖 Agency Handbook is live — SOPs, custody protocol, clearance policy and the onboarding checklist. Read it this week."),
  ("marcus", "Clearance Levels & Access Policy is the one to internalise — the masks you see in the live tables are explained there."),
  ("maya", "If a table renders `••••` where you expect a number, that is ABAC, not a bug. Elevation requests go through your case manager, not IT."),
  ("nadia", "Handbook looks great. The custody protocol toggle about common mistakes should be mandatory reading."),
  ("hannah", "It is now. Custody quiz moves to Fridays, first session this week."))
T("general",
  ("sofia", "Reminder: case board triage every Monday 10:00. Mission Control page has the live board embedded — statuses must be accurate before the meeting."),
  ("david", "NA cases are triaged. Broken Compass stays open-high; Tom has the conn."),
  ("tom", "Ack. Wiki updated with the Kestrel Marine angle."))
T("general",
  ("maya", "Maintenance window tonight 22:00–22:30 CET: gateway certs rotate. Sessions survive, video calls will drop for ~2 minutes."),
  ("viktor", "Noted — we'll keep the static post on radio during the window."),
  ("maya", "Done early. All services green."))
T("general",
  ("isabel", "Legal reminder: anything classified *privileged* (lawyer–client intercepts) does not get quoted in chat, wikis, or reports. Reference the COMM id and route through me."),
  ("jack", "Ash Garden team is aware — all surveillance product on Petrov goes through your screen first."),
  ("isabel", "Appreciated. Same applies to COMM-0139 on Nightfall."))
T("general",
  ("omar", "Evidence Gallery pages are up: Financial, Digital, Surveillance, Documents + the Q2 custody audit. Sanitised scans only — the live register stays the record."),
  ("grace", "The quarantine flag on EV-0055 is very visible. Good."),
  ("hannah", "That's the point. Deep verification is running; update lands on the audit page."))
T("general",
  ("robert", "Finance note: Q2 budget reconciliation needs case budgets confirmed by Thursday. Case managers, check your rows on the live board."),
  ("sofia", "EU cases confirmed."),
  ("david", "NA confirmed."),
  ("robert", "Thanks both. Quiet Storm's budget line moves to critical-priority pool."))
T("general",
  ("leila", "The espresso machine on 3 is doing the thing again where it dispenses sadness."),
  ("tom", "Filed under: cold case."),
  ("maya", "I fixed the firmware once. I will not be doing that again."),
  ("helena", "Procurement of a new machine is approved before someone opens an operation on it."))
T("general",
  ("yuki", "APAC sync moves to 08:00 CET on Wednesdays so Priya and I overlap with the EU morning."),
  ("priya", "Works for me — calendar updated."))
T("general",
  ("marcus", "All-hands Friday 15:00: Red Meridian referral status, Nightfall progress, and the Q2 custody findings. War Room for command, stream for everyone else."),
  ("amara", "Will the custody refresher be scheduled there too?"),
  ("hannah", "Yes — transport couriers first, everyone else within the month."))
T("general",
  ("erik", "PSA from analysis: if you cite a transaction in a wiki, use the TXN id. Amounts differ per clearance view, ids do not."),
  ("carlos", "+1. Same for subjects — alias collisions are real, S-ids only."),
  ("priya", "Two different people both called “Halcyon”. Ask me how I know."))
T("general",
  ("maya", "Password rotation due this week for everyone with clearance 4+. The policy engine will start nagging you Wednesday."),
  ("marcus", "Rotated. The nag is effective and mildly threatening — well done."),
  ("maya", "It escalates. You do not want to see level three."))
T("general",
  ("helena", "Board review went well. Special mention for the custody audit and the watchlist memo — the two-signal rule got quoted back at me approvingly."),
  ("hannah", "Team effort — the field teams are the ones logging both ends of every hand-off now."),
  ("priya", "And nobody has tried to add a counterparty on vibes for three whole weeks."),
  ("helena", "Progress."))
T("general",
  ("isabel", "New template for records requests is in Report Writing Standards. Use it — the old one had a paragraph a judge described as 'optimistic'."),
  ("pierre", "Using it for the freeport access-log request today."),
  ("yuki", "Same for the APAC registry pulls."))
T("general",
  ("david", "Friendly reminder the all-hands stream starts 15:00 sharp. Last week we lost four minutes to someone's bluetooth headphones."),
  ("tom", "It was not me."),
  ("leila", "It was absolutely you."),
  ("tom", "It was absolutely me."))

# ======================= #case-ops (≈55) =======================
T("case-ops",
  ("marcus", "Nightfall standup: EV-0084 ledger analysis is in — paired phantom-freight entries confirmed. Erik's pattern memo is on my desk before Thursday's War Room."),
  ("amara", "Custody on EV-0084 is clean, four entries, verified. The ledger pages are imaged and in the vault."),
  ("hannah", "EV-0086 hard drive imaging done. Wallet artefacts extracted and handed to analysis."),
  ("marcus", "Good. Jack — the contract (EV-0087)?"),
  ("jack", "Phantom freight terms confirmed: cargo never moved on any of the six bookings. Annotated copy is on the case wiki."))
T("case-ops",
  ("sofia", "Red Meridian review: legal needs the exhibit list final by Wednesday. EV-0055 stays OUT of the package until forensics clears it."),
  ("pierre", "Manifest set EV-0017 is in and verified — the export valuation model holds without the tape."),
  ("isabel", "Confirmed. The referral is stronger with a shorter, cleaner exhibit list anyway."),
  ("marcus", "Agreed. If EV-0055 clears later we amend; we do not wait for it."))
T("case-ops",
  ("jack", "Ash Garden: subject did the Friday pattern again — notary, then the Goldquay storefront. Third consecutive week. Surveillance log updated."),
  ("grace", "Static post footage (EV-0076 continuation) is timestamped and sealed."),
  ("isabel", "Reminder — Petrov is a lawyer. Everything she says to a client is privileged until I screen it. Route the audio to me first."),
  ("jack", "Understood, same drill as last week."),
  ("david", "Burner phone graph (EV-0051) — any movement on the recurring SIM?"),
  ("jack", "Forensics says same device family as the Nightfall COMM-0085 source. If that link verifies, we have one fixer on two cases."),
  ("marcus", "That would change the org chart of this whole thing. Keep it tight until verified."))
T("case-ops",
  ("tom", "Broken Compass: charter payments to Kestrel Marine land within 48h of each property closing — EV-0103 statement lines it up. Subpoena for charter manifests is drafting."),
  ("david", "Coordinate the Kestrel angle with Red Meridian — Grace's marina lead touches the same shop."),
  ("tom", "Already cross-referenced on the wiki. Priya's graph has Kestrel at elevated watch."))
T("case-ops",
  ("yuki", "Quiet Storm: vendor #3's incorporation date is 21 days before the award window. The pattern Carlos flagged holds for all three vendors."),
  ("pierre", "Then the formation-agent comparison is the next move. Carlos and Priya have the registered-agent overlap memo due Friday."),
  ("sofia", "Booking it for Monday's triage. Also: casino credit reconciliation (EV-0071) — Robert needs the clearance-4 totals."),
  ("robert", "On it — residual is down to two unexplained lines."))
T("case-ops",
  ("amara", "Evidence note for everyone: when you hand off to transport, BOTH ends log. Origin-only logging is what bit us on EV-0055."),
  ("nadia", "Cobalt Ledger ran three exhibits through trial without a scratch because of exactly that discipline."),
  ("hannah", "And the refresher session is now mandatory. Friday, no exceptions."))
T("case-ops",
  ("marcus", "Nightfall: legal is drafting the Goldquay KYC subpoena package. Once served, analysis gets the exit-cluster confirmation within the week."),
  ("leila", "Field support ready if service needs an address verification on the Goldquay storefront."),
  ("marcus", "Noted — hold until legal gives the word."))
T("case-ops",
  ("david", "Assignments check: everyone's rows in the live `assignments` table must match reality before Friday. If you are on a case and not in the table, you do not exist."),
  ("tom", "Fixed mine — Broken Compass plus the Kestrel cross-support."),
  ("grace", "Mine show Ash Garden static + Red Meridian marina follow-up. Correct."))
T("case-ops",
  ("sofia", "Heads-up: Director wants a one-page brief per featured case for the board. Case wikis already carry the summary callout — keep them current and the briefs write themselves."),
  ("pierre", "Quiet Storm wiki is current as of this morning."),
  ("jack", "Ash Garden updated after tonight's rotation."))
T("case-ops",
  ("amara", "Nightfall evidence run complete: EV-0098 (second hard drive, site visit) is imaged. Wallet artefact set is larger than EV-0086's — analysis has both now."),
  ("hannah", "Hashes recorded at collection and transfer. Chain is clean."),
  ("marcus", "Erik — fold EV-0098 into the exit-cluster work before Thursday if you can."),
  ("amara", "He's already pulling it, saw the forensics ticket close an hour ago."))
T("case-ops",
  ("pierre", "Quiet Storm: freeport access-log request served using Isabel's new template. Expecting the logs within ten working days."),
  ("yuki", "The award-week windows are listed on the wiki so we can cross the logs the day they arrive."),
  ("sofia", "Good. That closes the last open records item on Quiet Storm."))
T("case-ops",
  ("nadia", "Cobalt Ledger archive request: prosecution wants the custody bundle for the appeal. All three exhibits, full logs."),
  ("hannah", "Bundle prepared and sealed — collecting signature from legal tomorrow."),
  ("isabel", "I'll sign at 09:00. The appeal has nothing on custody; this is belt and braces."))
T("case-ops",
  ("david", "Broken Compass: Novum Estates closed two more flips this month. If the mixer deposits follow within 48h again, that is cycle five and six."),
  ("tom", "Watching the deposit window now. EV-0103 statement format makes the matching almost mechanical."),
  ("erik", "Ping me the timestamps when they land — they go straight into the exit-cluster correlation."),
  ("tom", "Will do."))
T("case-ops",
  ("marcus", "Reminder: minutes from last Thursday's War Room are on the case wikis. If you were mentioned with an action item, it is now in the assignments table too."),
  ("leila", "Seen mine — address verification on the Goldquay storefront, holding for legal."),
  ("grace", "Mine too. Kestrel charter manager identity confirmation, with Priya."))

# ======================= #intel-analysts (≈40) =======================
T("intel-analysts",
  ("erik", "TXN pattern memo is up in my notebook: structuring under 10k via Goldquay — TXN-0010 (9,769.57 EUR wire), TXN-0002, TXN-0014. Sub-threshold density 3.1× corridor baseline."),
  ("priya", "That density figure is the headline. Baseline computed on which window?"),
  ("erik", "Rolling 90 days, masked series bucketed to 500-unit bands. Method note is in the toggle."),
  ("carlos", "And then TXN-0016 walks in — 306,454.56 EUR by hawala TO an exchange. Who settles six figures by hawala into Goldquay?"),
  ("erik", "Either operator-to-operator settlement or a mistake. Escalated to Marcus with the memo."),
  ("marcus", "Read it. Bring it to the War Room Thursday — that outlier reframes Nightfall's scale."))
T("intel-analysts",
  ("priya", "Counterparty graph refresh: Goldquay now touches FOUR cases (Nightfall, Ash Garden, Broken Compass, Quiet Storm). Westport Capital SA recurs post-conviction. Watchlist updated."),
  ("carlos", "Kestrel Marine at elevated too — Red Meridian marina lead plus Broken Compass charter trail."),
  ("helena", "This is the picture I want on one page for the board. Watchlist memo is exactly right — keep ids on every claim."),
  ("priya", "Will do. FIXER-01 stays an unresolved node until the SIM comparison lands."))
T("intel-analysts",
  ("carlos", "Hawala corridor: Pelican Freight's invoice cancellation rate is 31% vs 4% industry norm. Freight invoices as settlement memos — cancellation IS the settlement confirmation."),
  ("erik", "That inversion is beautiful. Does the 72h settlement window hold across both corridors?"),
  ("carlos", "NA leg yes, EU leg has two outliers — both brush TXN-0016's week."),
  ("priya", "Everything touches that week. Flagging it as an event window in the graph."))
T("intel-analysts",
  ("priya", "Alias collision resolved: “Halcyon” is S-0003 (Hassan Vidal) AND S-0009 (Gustav DeVries). Two people, one alias, zero relation. The dashboard join was silently merging them."),
  ("erik", "How long was it wrong?"),
  ("priya", "Since 02 June. Re-keyed everything to subject_id. Post-mortem note is in my notebook."),
  ("carlos", "Good catch — that merge would have poisoned the Quiet Storm vendor analysis."))
T("intel-analysts",
  ("erik", "Mixer exits: 03:00–05:00 UTC cluster correlates 0.78 with Goldquay settlement batches. If Thursday's batch repeats the offsets, it's automation."),
  ("marcus", "And if it's automation, subpoenaing the scheduler config becomes very interesting. Keep me posted."),
  ("erik", "Watch is booked. Results land here Thursday night."))
T("intel-analysts",
  ("carlos", "Sable Trust (BVI) profile check: TXN-0024 (76,102.38 EUR, invoice method) fits the residual-sink pattern exactly. Third independent signal."),
  ("priya", "Then it graduates from monitor to elevated next sweep, per the watchlist rules."),
  ("helena", "Approved. The two-signal rule is doing its job."))
T("intel-analysts",
  ("erik", "Dashboard note: aggregate views (count/sum by counterparty) come from the live tables, so they respect masks. Finance sees totals; we see densities. Reconcile through Robert, not screenshots."),
  ("priya", "The mask follows the data, not the pixels. It's in the clearance policy verbatim."),
  ("carlos", "Quoting the handbook in chat. We've become management."))
T("intel-analysts",
  ("erik", "EV-0098 artefacts are in. The second drive's wallet set overlaps EV-0086 on three addresses — same operator, different machines."),
  ("carlos", "Three shared addresses is enough to collapse them into one node in the graph."),
  ("priya", "Collapsed. Nightfall's subject cluster just got simpler and scarier at the same time."),
  ("marcus", "That sentence is going in my Thursday brief verbatim."))
T("intel-analysts",
  ("priya", "Kestrel charter manager identity: Grace's marina log plus the charter registry gives us a name. Holding it off-channel until verified — it goes in `subjects` first, chat second."),
  ("carlos", "Correct order. The registry pull is archived under the case so the sourcing survives review."),
  ("helena", "This thread is why the analysts channel exists. Carry on."))
T("intel-analysts",
  ("carlos", "Methodology share: the 31% cancellation figure for Pelican came from comparing issued vs settled invoices in the manifest set — happy to walk anyone through the query."),
  ("erik", "Do a ten-minute walkthrough Friday after the all-hands?"),
  ("carlos", "Booked. Bring your own masked views."),
  ("priya", "Attending. I want the cancellation-as-settlement-confirmation logic on the watchlist page."))
T("intel-analysts",
  ("erik", "Thursday batch result: the mixer exit offsets repeated within 90 seconds. It is automation."),
  ("marcus", "Then the scheduler config subpoena goes in the Goldquay package. Outstanding work."),
  ("priya", "Event window thesis strengthens too — automated settlement plus one manual six-figure hawala the same week reads like someone pressing the override button."),
  ("erik", "Agreed on all counts. Memo updated before the War Room."))

# ======================= #field (≈35) =======================
T("field",
  ("grace", "Marina follow-up (L-0022): second meeting confirmed, same berth. Counterparty matches a Kestrel Marine charter manager — photos logged, context only, no faces."),
  ("jack", "Textbook. Tag goes to the Red Meridian analyst thread."),
  ("sofia", "Logged. Identity confirmation task is with Priya."))
T("field",
  ("tom", "Plate from L-0079 spotted again at the freight forwarder's yard, 14:20. Second corroboration."),
  ("viktor", "Matches my earlier log at location L-21. The vehicle is the thread between subject and yard."),
  ("david", "Both entries are in `leads`. That's how it's done — 30 seconds of logging, weeks of value."))
T("field",
  ("nadia", "Friday courier watch (L-0048 / Red Meridian): bank alert corroborated across two cycles now. Third cycle this Friday completes the warrant package threshold."),
  ("leila", "I'll take the second eye on Friday. Rotation board updated."),
  ("nadia", "Confirmed. Radio checks on the quarter hour, abort criteria per the field guide."))
T("field",
  ("jack", "Ash Garden rotation: Grace and Viktor on static this week. Subject is counter-surveillance aware — eyes rotate every 40, no exceptions."),
  ("viktor", "Footage from last night sealed and logged as EV-0076 continuation. Hand-off logged at BOTH ends, before anyone asks."),
  ("hannah", "I saw. Custody compliance has visibly improved since the audit. Keep it up."))
T("field",
  ("leila", "Reminder from the SOP: contact reports within 12 hours. Mine from the records office visit is filed."),
  ("tom", "Filed mine too. The notary clerk talks a lot when you ask about parking."),
  ("grace", "The best sources don't know they are sources."))
T("field",
  ("sofia", "Ops note: no seizures on pattern alone. The Friday courier package waits for legal's warrant — anyone moving early answers to me and then to Isabel, in that order."),
  ("jack", "Understood. Field holds."),
  ("david", "And if anyone gets burned: SUNSET in this channel, fallback point, nothing else."))
T("field",
  ("viktor", "Kit check: long-lens rig back from forensics, locker 7. Radio batteries rotated. The static post chair remains a war crime."),
  ("grace", "Confirmed on all three. Bringing my own cushion."),
  ("leila", "Requisition for a new chair filed under 'operational necessity'."),
  ("david", "Approved. Morale is operational."))
T("field",
  ("nadia", "Friday cycle three complete: courier, same route, same timing, bag swap at the kiosk. Warrant threshold met — package goes to legal Monday."),
  ("jack", "Clean work. Log both plates and the kiosk vendor's hours in `leads` before you stand down."),
  ("nadia", "Already in. L-0048 updated with all three cycles."),
  ("sofia", "Seen. Legal has it first thing Monday."))
T("field",
  ("tom", "Yard watch: the L-0079 vehicle left with a trailer tonight, first time. Followed to the ring road per the pre-cleared route, then broke off."),
  ("viktor", "Correct call — the route past the ring road is not cleared and the subject checks mirrors."),
  ("david", "Trailer detail goes to Red Meridian's analyst thread. That yard keeps earning its surveillance budget."))
T("field",
  ("grace", "Ash Garden Friday report: notary, then Goldquay storefront, fourth consecutive week. Pattern threshold met. Footage sealed, hand-off logged both ends."),
  ("jack", "Four for four. It goes on the wiki tonight and to Isabel's screening queue first."),
  ("isabel", "Queue position one. You'll have the release decision by Tuesday."))

# ======================= War Room (video, ≈8) =======================
T("war-room",
  ("helena", "War Room Thursday 09:00 — agenda: Nightfall TXN-0016 outlier, Red Meridian referral, Q2 custody findings. Erik presents first ten minutes."),
  ("marcus", "Confirmed. Pre-read: Erik's notebook memo + the watchlist page."),
  ("sofia", "Joining from the EU room. Red Meridian exhibit list will be final by then."),
  ("david", "NA dialling in. I'll bring the Broken Compass charter subpoena status."),
  ("helena", "Minutes go on the case wikis within 24h, per SOP."))
T("war-room",
  ("marcus", "Link check for Thursday — everyone confirm the video channel works from your kit."),
  ("sofia", "Working here."),
  ("david", "Same."))

# ======================= DMs (≈24) =======================
T("dm-erik-priya",
  ("erik", "Your alias-collision catch saved my density model — I was about to bucket by alias for the dedupe pass."),
  ("priya", "We all almost did. subject_id or nothing now."),
  ("erik", "Deal. Also — look at TXN-0016's week in your graph. Everything converges on it."),
  ("priya", "Saw it. I'm calling it the event window. If the Thursday batch confirms automation, that week is when someone settled the books."),
  ("erik", "If you put 'event window' on the watchlist page, attach both our ids to it."),
  ("priya", "Two signals, written down. I know the rules — I wrote them."))
T("dm-marcus-sofia",
  ("marcus", "Red Meridian: can you hold the referral package until Hannah's deep verification report? If EV-0055 clears, we amend; if not, the package is already clean."),
  ("sofia", "Holding until Wednesday noon, then it ships regardless. Legal agrees the shorter list is stronger."),
  ("marcus", "Agreed. One more thing — staffing. If the SIM link between Ash Garden and Nightfall verifies, I want one analyst across both."),
  ("sofia", "Erik is the obvious pick but he's at capacity. Priya takes the cross-case node, Erik keeps the patterns."),
  ("marcus", "Good split. Put it in Monday's triage."))
T("dm-jack-grace",
  ("jack", "Friday rotation — can you take the early shift at the static post? Viktor has the courier watch with Nadia."),
  ("grace", "Yes, but I need the long-lens kit back from forensics by Thursday."),
  ("jack", "Maya signed it back in this morning. It's in locker 7."),
  ("grace", "Then we're set. If the subject does the notary-Goldquay run again, that's four consecutive Fridays — pattern threshold met."),
  ("jack", "And THEN we let legal do their thing. By the book on this one — she's a lawyer, she'll see anything sloppy."))
T("dm-helena-marcus",
  ("helena", "Before Thursday: the TXN-0016 outlier — does it change Nightfall's budget line? Six-figure settlements mean a bigger ring than we scoped."),
  ("marcus", "Honestly, yes. If the fixer link verifies we're looking at one network behind three operations. I'd rather re-scope now than mid-referral."),
  ("helena", "Then bring a consolidated proposal Thursday. One network, one task force, shared analyst pool."),
  ("marcus", "Drafting it tonight. Working name: MERIDIAN GATE."),
  ("helena", "Approved as a working name. And Marcus — good catch escalating the outlier fast."))

# ---- timestamping ------------------------------------------------------------
# Spread threads over the last 14 days, oldest first, messages 2-6 min apart.
MIN_14D = 14 * 24 * 60
events = []  # (msg_uuid, channel_key, author, text, minutes_ago)
n_threads = len(THREADS)
for ti, (chan, msgs) in enumerate(THREADS):
    base = MIN_14D - int((ti + 1) * (MIN_14D - 90) / (n_threads + 1)) + rng.randint(-40, 40)
    offset = max(base, 75)
    for mi, (author, text) in enumerate(msgs):
        mid = uid(f"msg:{chan}:{ti}:{mi}")
        events.append((mid, chan, author, text, offset))
        offset -= rng.randint(2, 6)

# reactions: (msg uuid5 key parts, reactor, emoji)
REACTIONS = [
    (("general", 0, 0), "amara", "👍"), (("general", 0, 0), "erik", "👍"),
    (("general", 0, 0), "grace", "🎉"),
    (("general", 6, 0), "tom", "😂"), (("general", 6, 1), "leila", "😂"),
    (("general", 6, 3), "maya", "👍"),
    (("case-ops", 2, 5), "marcus", "👀"), (("case-ops", 2, 5), "david", "🔥"),
    (("case-ops", 0, 4), "marcus", "✅"),
    (("intel-analysts", 0, 4), "priya", "🔥"), (("intel-analysts", 0, 4), "carlos", "🔥"),
    (("intel-analysts", 3, 0), "erik", "🎯"), (("intel-analysts", 3, 0), "helena", "👍"),
    (("field", 1, 2), "jack", "✅"), (("field", 0, 0), "sofia", "👍"),
    (("war-room", 0, 0), "sofia", "✅"), (("war-room", 0, 0), "david", "✅"),
    (("dm-helena-marcus", 0, 4), "marcus", "🙏"),
]
# index events by (chan, thread, msg) for reactions: rebuild mapping
_msg_uuid = {}
for ti, (chan, msgs) in enumerate(THREADS):
    for mi in range(len(msgs)):
        _msg_uuid[(chan, ti, mi)] = uid(f"msg:{chan}:{ti}:{mi}")

# thread-local indexes are global across THREADS list; recompute per-channel thread index
_chan_threads = {}
_key_fix = {}
for ti, (chan, msgs) in enumerate(THREADS):
    local = _chan_threads.setdefault(chan, 0)
    for mi in range(len(msgs)):
        _key_fix[(chan, local, mi)] = (chan, ti, mi)
    _chan_threads[chan] = local + 1

# edited messages: (channel, local thread, msg index)
EDITED = [("general", 2, 0), ("case-ops", 3, 0), ("intel-analysts", 1, 0)]

# ---- emit chat SQL -----------------------------------------------------------
chat = [
    "-- Generated by tools/seeds/seed_agency_wiki.py — chat + feed backfill.",
    "-- Idempotent: fixed uuid5 ids, ON CONFLICT DO NOTHING everywhere. Safe to re-run.",
    "BEGIN;",
]

for key, c in CH.items():
    cid = uid(f"channel:{key}")
    chat.append(
        "INSERT INTO public.osionos_channels (id, workspace_id, kind, name, topic, created_by, "
        "is_private, abac, created_at, updated_at) VALUES ("
        f"'{cid}', '{WS}', '{c['kind']}', {sqlstr(c['name'])}, {sqlstr(c['topic'])}, "
        f"'{P(c['created_by'])}', {'true' if c['private'] else 'false'}, '{{}}'::jsonb, "
        f"now() - interval '15 days', now()) ON CONFLICT (id) DO NOTHING;")
    for m in c["members"]:
        role = "owner" if m == c["created_by"] else "member"
        chat.append(
            "INSERT INTO public.osionos_channel_members (channel_id, user_id, role, joined_at) "
            f"VALUES ('{cid}', '{P(m)}', '{role}', now() - interval '15 days') "
            "ON CONFLICT DO NOTHING;")

for key, a, b in DMS:
    dk = dm_key(a, b)
    cid = uid(f"channel:{key}")
    name = f"{PN(a)} & {PN(b)}"
    chat.append(
        "INSERT INTO public.osionos_channels (id, workspace_id, kind, name, created_by, "
        "is_private, abac, dm_key, created_at, updated_at) VALUES ("
        f"'{cid}', '{WS}', 'dm', {sqlstr(name)}, '{P(a)}', true, '{{}}'::jsonb, {sqlstr(dk)}, "
        "now() - interval '13 days', now()) ON CONFLICT (dm_key) DO NOTHING;")
    for m in (a, b):
        chat.append(
            "INSERT INTO public.osionos_channel_members (channel_id, user_id, role, joined_at) "
            f"SELECT id, '{P(m)}', 'member', now() - interval '13 days' "
            f"FROM public.osionos_channels WHERE dm_key = {sqlstr(dk)} "
            "ON CONFLICT DO NOTHING;")

DM_KEY_BY_CHAN = {key: dm_key(a, b) for key, a, b in DMS}
edited_uuids = {_msg_uuid[_key_fix[k]] for k in EDITED}

msg_count = 0
for mid, chan, author, text, minutes in events:
    created = f"now() - interval '{minutes} minutes'"
    edited = f"now() - interval '{max(minutes - 9, 5)} minutes'" if mid in edited_uuids else "NULL"
    body = text
    if chan in DM_KEY_BY_CHAN:
        chan_sql = (f"(SELECT id FROM public.osionos_channels WHERE dm_key = "
                    f"{sqlstr(DM_KEY_BY_CHAN[chan])})")
    else:
        chan_sql = f"'{uid('channel:' + chan)}'"
    chat.append(
        "INSERT INTO public.osionos_messages (id, channel_id, author_id, content, attachments, "
        f"created_at, edited_at) VALUES ('{mid}', {chan_sql}, '{P(author)}', {sqlstr(body)}, "
        f"'[]'::jsonb, {created}, {edited}) ON CONFLICT (id) DO NOTHING;")
    msg_count += 1

react_count = 0
for local_key, reactor, emoji in REACTIONS:
    real = _key_fix.get(local_key)
    if not real:
        continue
    chat.append(
        "INSERT INTO public.osionos_message_reactions (message_id, user_id, emoji, created_at) "
        f"VALUES ('{_msg_uuid[real]}', '{P(reactor)}', {sqlstr(emoji)}, now() - interval '1 day') "
        "ON CONFLICT DO NOTHING;")
    react_count += 1

# ---- feed backfill: likes + comments on the wiki pages ------------------------
LIKES = {
    "case-nightfall": ["marcus", "erik", "amara", "jack", "helena", "priya"],
    "case-cobalt": ["nadia", "helena", "sofia", "isabel"],
    "case-redmeridian": ["marcus", "sofia", "pierre", "hannah", "grace"],
    "case-quietstorm": ["pierre", "carlos", "robert", "yuki"],
    "case-ashgarden": ["jack", "grace", "viktor", "isabel"],
    "case-brokencompass": ["tom", "david", "priya"],
    "handbook": ["helena", "marcus", "sofia", "nadia", "leila", "maya"],
    "sop": ["amara", "tom", "isabel"],
    "custody": ["hannah", "omar", "amara", "nadia"],
    "mission-control": ["helena", "marcus", "david", "erik", "robert"],
}
COMMENTS = [
    ("custody", "amara", "Custody log for EV-0042 updated — please re-verify.", 4300),
    ("custody", "hannah", "Re-verification booked for Thursday. EV-0055 deep check still running.", 4180),
    ("case-redmeridian", "hannah", "Reminder: EV-0055 stays out of the referral package until my report lands.", 3900),
    ("case-redmeridian", "isabel", "Exhibit list reviewed — clean without the tape. Ship it Wednesday.", 3700),
    ("case-nightfall", "erik", "TXN pattern memo linked — the 3.1× density figure is the headline for Thursday.", 5200),
    ("case-nightfall", "isabel", "COMM-0139 is privileged — do not quote it here, reference the id only.", 5100),
    ("case-ashgarden", "isabel", "All Petrov intercepts screened this week — two released to analysis, one held.", 2900),
    ("case-ashgarden", "grace", "Static post log sealed and handed off — both ends signed this time.", 2800),
    ("case-quietstorm", "robert", "Casino credit reconciliation: residual down to two lines. Update on the wiki.", 2400),
    ("case-brokencompass", "priya", "Kestrel Marine raised to elevated on the watchlist — two-signal rule met.", 2000),
    ("case-cobalt", "helena", "Excellent retrospective. The Westport recurrence note directly feeds Nightfall.", 6100),
    ("handbook", "leila", "Onboarding checklist is genuinely useful — finished week one with zero surprises.", 7000),
    ("mission-control", "marcus", "Live board is now the agenda for Monday triage — keep statuses current.", 8000),
    ("sop", "tom", "Contact-report-within-12h rule acknowledged. Filed tonight's from the yard.", 3300),
]
like_count = 0
for pkey, users in LIKES.items():
    pid = uid(f"page:{pkey}")
    for i, u in enumerate(users):
        chat.append(
            "INSERT INTO public.osionos_feed_likes (page_id, user_id, created_at) "
            f"VALUES ('{pid}', '{P(u)}', now() - interval '{rng.randint(600, 9000)} minutes') "
            "ON CONFLICT DO NOTHING;")
        like_count += 1
for i, (pkey, author, text, minutes) in enumerate(COMMENTS):
    cid = uid(f"feed-comment:{i}:{pkey}")
    chat.append(
        "INSERT INTO public.osionos_feed_comments (id, page_id, author_id, content, created_at) "
        f"VALUES ('{cid}', '{uid('page:' + pkey)}', '{P(author)}', {sqlstr(text)}, "
        f"now() - interval '{minutes} minutes') ON CONFLICT (id) DO NOTHING;")

chat.append("COMMIT;")
chat_out = os.path.join(HERE, "seed_agency_chat.sql")
with open(chat_out, "w") as fh:
    fh.write("\n".join(chat) + "\n")

print(f"pages: {len(PAGES)}  channels: {len(CH) + len(DMS)}  messages: {msg_count}  "
      f"reactions: {react_count}  likes: {like_count}  comments: {len(COMMENTS)}", file=sys.stderr)
print(wiki_out)
print(chat_out)
