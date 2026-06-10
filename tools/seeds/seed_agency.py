#!/usr/bin/env python3
"""seed_agency.py — deterministic case-file data for the Binocle agency tenant.

Generates seed_agency.sql (idempotent INSERT ... ON CONFLICT DO NOTHING)
against the `agency` database created by
apps/baas/mini-baas-infra/scripts/seed/agency-tenant.sh.

Reads tools/seeds/.agency-people.env for the owner uuid (owner_id stamp on
every row, matching the platform's write-path convention) and the employee
roster (assignments.employee_email, evidence.collected_by, reports.author).

Row targets: cases 40, subjects 60, locations 50, evidence 120, leads 80,
transactions 150, vehicles 30, communications 200, reports 40,
assignments 100 — ~920 rows total, FK-linked so /query/v1/graph yields a
connected investigation graph.
"""
from __future__ import annotations

import random
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
PEOPLE_ENV = HERE / ".agency-people.env"
TENANT_ENV = HERE.parent.parent / "apps" / "baas" / "mini-baas-infra" / ".agency-tenant.env"
OUT = HERE / "seed_agency.sql"

random.seed(42)


def load_db_id() -> str:
    for line in TENANT_ENV.read_text().splitlines():
        if line.startswith("AGENCY_DB_ID="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("run agency-tenant.sh first (missing AGENCY_DB_ID)")


def load_people() -> tuple[str, list[dict]]:
    owner, people = "", []
    for line in PEOPLE_ENV.read_text().splitlines():
        if line.startswith("AGENCY_OWNER_UUID="):
            owner = line.split("=", 1)[1].strip()
        elif line.startswith("AGENCY_PERSON_"):
            if line.startswith("AGENCY_PERSON_COUNT"):
                continue
            parts = line.split("=", 1)[1].split("|")
            people.append({
                "uuid": parts[0], "email": parts[1], "name": parts[2],
                "role": parts[3], "dept": parts[4], "clearance": int(parts[5]),
                "region": parts[6],
            })
    if not owner or not people:
        raise SystemExit("run seed_agency_people.sh first (missing .agency-people.env)")
    return owner, people


def q(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def ts(base: datetime, max_days: int) -> str:
    return (base + timedelta(days=random.randint(0, max_days),
                             hours=random.randint(0, 23),
                             minutes=random.randint(0, 59))).strftime("%Y-%m-%d %H:%M:%S+00")


OPS = ["Nightfall", "Cobalt Ledger", "Silent Harbor", "Glass Orchid", "Iron Veil",
       "Amber Crossing", "Hollow Crown", "Red Meridian", "Paper Tiger", "Black Tide",
       "Marble Fox", "Quiet Storm", "Golden Thread", "Ash Garden", "Winter Lantern",
       "Broken Compass", "Velvet Chain", "Salt Mirage", "Cedar Gate", "Phantom Ledger",
       "Blue Asphalt", "Mirror Lake", "Stone Whisper", "Last Orchard", "Neon Distillery",
       "Cold Archive", "Topaz Relay", "Drift Anchor", "Sable Run", "Open Window",
       "Pale Horizon", "Crimson Wake", "Static Veil", "Lone Marker", "Deep Current",
       "Bright Cellar", "Grey Lattice", "Final Compass", "Echo Vault", "Glass Bridge"]
CASE_STATUS = ["open", "open", "open", "active_surveillance", "analysis", "review", "closed", "cold"]
PRIORITIES = ["critical", "high", "medium", "low"]
CLASSIF = ["restricted", "confidential", "internal", "internal"]
CLIENTS = ["Meridian Bank AG", "Helios Insurance", "EU AML Taskforce", "Castellan Holdings",
           "Private — Estate of R. Voss", "Northgate Logistics", "Apex Reinsurance",
           "Ministry of Finance (anon.)", "Orpheus Capital", "Wexford & Pale LLP"]
FIRST = ["Viktor", "Lena", "Dmitri", "Carmen", "Hassan", "Ingrid", "Paulo", "Mei", "Aldo",
         "Petra", "Sergei", "Lucia", "Farid", "Anneke", "Bruno", "Katya", "Otto", "Renata",
         "Ivan", "Maribel", "Janus", "Odile", "Ricardo", "Saskia", "Emil", "Noor", "Gustav",
         "Beatriz", "Anton", "Zofia"]
LAST = ["Morozov", "Keller", "Albrecht", "Duarte", "Rahimi", "Sørensen", "Vidal", "Chen",
        "Romano", "Novak", "Baranov", "Esposito", "Haddad", "Visser", "Graf", "Sokolova",
        "Brandt", "Costa", "Petrov", "Iglesias", "Kovac", "Marchand", "Silva", "DeVries",
        "Wagner", "Hakim", "Lindgren", "Almeida", "Volkov", "Mazur"]
RISK = ["low", "medium", "medium", "high", "high", "critical"]
OCCUP = ["import/export broker", "shell company director", "art dealer", "crypto trader",
         "logistics manager", "private banker", "casino host", "yacht broker",
         "real-estate agent", "freight forwarder", "lawyer", "accountant"]
CITIES = [("Zurich", "CH", 47.3769, 8.5417), ("Rotterdam", "NL", 51.9244, 4.4777),
          ("Marseille", "FR", 43.2965, 5.3698), ("Hamburg", "DE", 53.5511, 9.9937),
          ("Vienna", "AT", 48.2082, 16.3738), ("Lisbon", "PT", 38.7223, -9.1393),
          ("Valletta", "MT", 35.8989, 14.5146), ("Dubai", "AE", 25.2048, 55.2708),
          ("Singapore", "SG", 1.3521, 103.8198), ("Panama City", "PA", 8.9824, -79.5199),
          ("Geneva", "CH", 46.2044, 6.1432), ("Antwerp", "BE", 51.2194, 4.4025)]
LOC_KINDS = ["residence", "business", "warehouse", "safehouse", "marina", "office",
             "storage unit", "restaurant", "gallery", "freeport vault"]
EV_KINDS = ["document", "photograph", "ledger", "hard drive", "phone dump", "bank statement",
            "wire receipt", "surveillance tape", "shipping manifest", "contract", "burner phone"]
LEAD_SRC = ["informant", "wiretap", "open source", "bank alert", "customs flag",
            "anonymous tip", "field observation", "financial analysis"]
CRED = ["unverified", "low", "medium", "medium", "high", "confirmed"]
LEAD_STATUS = ["new", "investigating", "corroborated", "dead_end", "escalated"]
CURRENCIES = ["EUR", "EUR", "USD", "CHF", "AED", "USDT"]
COUNTERPARTIES = ["Aurelia Trade FZE", "Westport Capital SA", "Lumen Art Holdings",
                  "Kestrel Marine Ltd", "Hyperion Commodities", "Sable Trust (BVI)",
                  "Goldquay Exchange", "Pelican Freight LLC", "Novum Estates",
                  "Cygnus Consulting GmbH"]
METHODS = ["wire", "wire", "cash deposit", "crypto", "hawala", "invoice"]
CHANNELS = ["phone", "phone", "email", "encrypted app", "sms", "in person"]
COMM_CLASS = ["routine", "routine", "relevant", "relevant", "incriminating", "privileged"]
MAKES = [("BMW", "740d"), ("Mercedes", "S580"), ("Audi", "RS6"), ("Range Rover", "Sport"),
         ("Porsche", "Cayenne"), ("Toyota", "Land Cruiser"), ("VW", "Transporter"),
         ("Volvo", "XC90"), ("Tesla", "Model S"), ("Ford", "Transit")]
COLORS = ["black", "anthracite", "silver", "white", "navy", "grey"]
REPORT_STATUS = ["draft", "review", "review", "final", "final"]
ROLES_ON_CASE = ["lead", "support", "surveillance", "analysis", "forensics", "legal review"]

BASE = datetime(2025, 6, 1)


def main() -> None:
    owner, people = load_people()
    inv_names = [p["name"] for p in people if p["dept"] in ("investigations", "operations", "command")]
    emails = [p["email"] for p in people]
    sql: list[str] = [
        "-- generated by tools/seeds/seed_agency.py — idempotent agency case-file data",
        "BEGIN;",
    ]

    def emit(table: str, cols: list[str], rows: list[list]) -> None:
        sql.append(f"-- {table}: {len(rows)} rows")
        for row in rows:
            vals = ", ".join(q(v) for v in row)
            sql.append(f"INSERT INTO public.{table} ({', '.join(cols)}) "
                       f"VALUES ({vals}) ON CONFLICT (id) DO NOTHING;")

    # cases ──────────────────────────────────────────────────────────────────
    cases = []
    for i in range(1, 41):
        status = random.choice(CASE_STATUS)
        opened = ts(BASE - timedelta(days=400), 380)
        closed = ts(BASE, 200) if status in ("closed", "cold") else None
        cases.append([i, f"BIA-{2025 + (i % 2)}-{i:03d}", f"Operation {OPS[i - 1]}",
                      status, random.choice(PRIORITIES), random.choice(CLASSIF),
                      round(random.uniform(8_000, 250_000), 2), random.choice(inv_names),
                      random.choice(CLIENTS), opened, closed,
                      f"Investigation into {random.choice(['suspected money laundering', 'asset concealment', 'procurement fraud', 'sanctions evasion', 'art-market fraud', 'insurance fraud', 'corporate espionage'])} "
                      f"involving {random.choice(['offshore structures', 'a shipping network', 'shell companies', 'a freeport vault', 'crypto mixers', 'trade mis-invoicing'])}.",
                      owner])
    emit("cases", ["id", "code", "title", "status", "priority", "classification", "budget",
                   "lead_investigator", "client", "opened_at", "closed_at", "summary", "owner_id"], cases)

    # subjects ───────────────────────────────────────────────────────────────
    subjects = []
    used = set()
    for i in range(1, 61):
        while True:
            name = f"{random.choice(FIRST)} {random.choice(LAST)}"
            if name not in used:
                used.add(name)
                break
        alias = random.choice([None, None, f"“{random.choice(['The Banker', 'Marquis', 'Cashmere', 'Doc', 'The Courier', 'Magpie', 'Halcyon', 'Brick'])}”"])
        dob = (datetime(1955, 1, 1) + timedelta(days=random.randint(0, 14_000))).strftime("%Y-%m-%d")
        ssn = f"{random.randint(100, 999)}-{random.randint(10, 99)}-{random.randint(1000, 9999)}"
        subjects.append([i, random.randint(1, 40), name, alias, ssn,
                         random.choice(["CH", "DE", "RU", "FR", "IT", "NL", "AE", "MT", "PA", "CY"]),
                         random.choice(RISK), random.choice(OCCUP), dob,
                         random.choice([None, "Known to travel under secondary passport.",
                                        "Frequent contact with case principals.",
                                        "Cooperative witness — handle with care.",
                                        "Surveillance authorized by client mandate."]),
                         owner])
    emit("subjects", ["id", "case_id", "full_name", "alias", "ssn", "nationality",
                      "risk_level", "occupation", "date_of_birth", "notes", "owner_id"], subjects)

    # locations ──────────────────────────────────────────────────────────────
    locations = []
    for i in range(1, 51):
        city, country, lat, lng = random.choice(CITIES)
        kind = random.choice(LOC_KINDS)
        locations.append([i, f"{kind.title()} — {city} #{i}", kind,
                          f"{random.randint(1, 220)} {random.choice(['Quai', 'Strasse', 'Avenue', 'Laan', 'Via', 'Rua'])} {random.choice(LAST)}",
                          city, country,
                          round(lat + random.uniform(-0.05, 0.05), 6),
                          round(lng + random.uniform(-0.05, 0.05), 6),
                          random.random() < 0.3, owner])
    emit("locations", ["id", "label", "kind", "address", "city", "country", "lat", "lng",
                       "surveillance_active", "owner_id"], locations)

    # evidence ───────────────────────────────────────────────────────────────
    evidence = []
    for i in range(1, 121):
        kind = random.choice(EV_KINDS)
        evidence.append([i, random.randint(1, 40), kind,
                         f"{kind.title()} recovered during {random.choice(['site visit', 'records request', 'surveillance op', 'source meeting', 'forensic imaging'])}.",
                         f"BIA-EV-{i:04d} sealed; custody log {random.randint(2, 6)} entries",
                         random.randint(1, 50), random.choice([p['name'] for p in people]),
                         ts(BASE - timedelta(days=300), 290), random.random() < 0.92, owner])
    emit("evidence", ["id", "case_id", "kind", "description", "chain_of_custody",
                      "storage_location_id", "collected_by", "collected_at",
                      "integrity_verified", "owner_id"], evidence)

    # leads ──────────────────────────────────────────────────────────────────
    leads = []
    for i in range(1, 81):
        leads.append([i, random.randint(1, 40), random.choice([None, random.randint(1, 60)]),
                      random.choice(LEAD_SRC), random.choice(CRED), random.choice(LEAD_STATUS),
                      random.choice(["Subject seen meeting unknown male at marina.",
                                     "Invoice totals diverge from customs declaration.",
                                     "New shell entity registered with shared director.",
                                     "Repeated structuring just under reporting threshold.",
                                     "Vehicle plate matched at second location.",
                                     "Informant reports cash courier run on Fridays.",
                                     "Encrypted app group references 'the gallery'."]),
                      ts(BASE - timedelta(days=250), 240), owner])
    emit("leads", ["id", "case_id", "subject_id", "source", "credibility", "status",
                   "detail", "received_at", "owner_id"], leads)

    # transactions ───────────────────────────────────────────────────────────
    txns = []
    for i in range(1, 151):
        flagged = random.random() < 0.35
        amount = round(random.choice([random.uniform(900, 9_900),
                                      random.uniform(9_000, 9_999),
                                      random.uniform(10_000, 480_000)]), 2)
        txns.append([i, random.randint(1, 60), amount, random.choice(CURRENCIES),
                     random.choice(COUNTERPARTIES),
                     f"{random.choice(['CH', 'MT', 'AE', 'VG', 'PA'])}{random.randint(10**10, 10**11 - 1)}",
                     flagged, ts(BASE - timedelta(days=365), 360), random.choice(METHODS), owner])
    emit("transactions", ["id", "subject_id", "amount", "currency", "counterparty",
                          "account_ref", "flagged", "executed_at", "method", "owner_id"], txns)

    # vehicles ───────────────────────────────────────────────────────────────
    vehicles = []
    for i in range(1, 31):
        make, model = random.choice(MAKES)
        plate = f"{random.choice(['ZH', 'GE', 'HH', 'B', 'NL', 'F'])}-{random.randint(1000, 99999)}"
        vehicles.append([i, random.choice([None, random.randint(1, 60)]), plate, make, model,
                         random.choice(COLORS), random.randint(2012, 2025),
                         random.choice([None, random.randint(1, 50)]), owner])
    emit("vehicles", ["id", "owner_subject_id", "plate", "make", "model", "color", "year",
                      "last_seen_location_id", "owner_id"], vehicles)

    # communications ─────────────────────────────────────────────────────────
    comms = []
    for i in range(1, 201):
        comms.append([i, random.randint(1, 60), random.choice(CHANNELS),
                      random.choice([f"{random.choice(FIRST)} {random.choice(LAST)}",
                                     "unknown number", "unregistered SIM",
                                     random.choice(COUNTERPARTIES)]),
                      ts(BASE - timedelta(days=200), 195),
                      random.choice(["Arranged meeting; location referenced obliquely.",
                                     "Discussed 'paperwork' for upcoming shipment.",
                                     "Payment confirmation — amount matches txn pattern.",
                                     "Subject anxious about 'the audit'.",
                                     "Travel plans: short-notice flight, cash ticket.",
                                     "Mentioned contact at the freeport by first name.",
                                     "Routine personal call — no case relevance."]),
                      random.choice(COMM_CLASS), random.randint(1, 40), owner])
    emit("communications", ["id", "subject_id", "channel", "counterparty", "intercepted_at",
                            "summary", "classification", "case_id", "owner_id"], comms)

    # reports ────────────────────────────────────────────────────────────────
    reports = []
    for i in range(1, 41):
        author = random.choice([p["name"] for p in people if p["dept"] in ("analysis", "investigations", "forensics")])
        reports.append([i, i, f"{random.choice(['Interim', 'Surveillance', 'Financial', 'Forensic', 'Closing'])} report — Operation {OPS[i - 1]}",
                        author, random.choice(REPORT_STATUS), random.choice(CLASSIF),
                        ts(BASE - timedelta(days=100), 95),
                        f"Findings summary for Operation {OPS[i - 1]}: "
                        f"{random.choice(['fund flows traced through three jurisdictions', 'subject network mapped, two new principals identified', 'evidence chain complete and verified', 'surveillance window produced actionable pattern-of-life', 'ledger reconstruction shows systematic skimming'])}.",
                        owner])
    emit("reports", ["id", "case_id", "title", "author", "status", "classification",
                     "published_at", "body", "owner_id"], reports)

    # assignments ────────────────────────────────────────────────────────────
    assignments = []
    for i in range(1, 101):
        assignments.append([i, ((i - 1) % 40) + 1, random.choice(emails),
                            random.choice(ROLES_ON_CASE), round(random.uniform(4, 160), 1),
                            round(random.uniform(45, 180), 2),
                            (BASE - timedelta(days=random.randint(10, 300))).strftime("%Y-%m-%d"),
                            random.random() < 0.7, owner])
    emit("assignments", ["id", "case_id", "employee_email", "role_on_case", "hours",
                         "hourly_rate", "started_at", "active", "owner_id"], assignments)

    # edges — curated investigative links (PRIMARY graph edge source); node
    # ids are `<mountId>:<table>:<pk>` per the graph contract ────────────────
    db_id = load_db_id()
    nid = lambda table, pk: f"{db_id}:{table}:{pk}"  # noqa: E731
    edges, eid = [], 0

    def edge(frm: str, to: str, etype: str, label: str, directed: bool = True) -> None:
        nonlocal eid
        eid += 1
        edges.append([eid, frm, to, etype, label, directed, owner])

    seen_pairs = set()
    for _ in range(30):  # subject ↔ subject associations
        a, b = random.randint(1, 60), random.randint(1, 60)
        if a == b or (min(a, b), max(a, b)) in seen_pairs:
            continue
        seen_pairs.add((min(a, b), max(a, b)))
        edge(nid("subjects", a), nid("subjects", b), "associate",
             random.choice(["business partner", "family", "frequent contact",
                            "co-director", "courier for", "introduced by informant"]),
             directed=False)
    for _ in range(25):  # subject → location patterns of life
        edge(nid("subjects", random.randint(1, 60)), nid("locations", random.randint(1, 50)),
             "frequents", random.choice(["weekly visits", "registered address",
                                         "meeting spot", "storage access", "owns via proxy"]))
    for _ in range(25):  # cross-case discoveries: case → subject outside its FK chain
        edge(nid("cases", random.randint(1, 40)), nid("subjects", random.randint(1, 60)),
             "involves", random.choice(["person of interest", "witness", "beneficial owner",
                                        "intermediary", "unconfirmed link"]))
    emit("edges", ["id", '"from"', '"to"', "type", "label", "directed", "owner_id"], edges)

    sql.append("COMMIT;")
    OUT.write_text("\n".join(sql) + "\n")
    total = 40 + 60 + 50 + 120 + 80 + 150 + 30 + 200 + 40 + 100 + len(edges)
    print(f"wrote {OUT} ({total} rows across 11 tables, {len(edges)} edges)")


if __name__ == "__main__":
    main()
