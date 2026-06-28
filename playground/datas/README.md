# playground/datas — practice datasets for every engine

A training ground for loading real datasets into **all of our Docker database engines** and
practicing the [CS50 SQL exercises](../../wiki/database-cli/cs50-sql/README.md) (and your own)
against each one.

```
playground/datas/
├── README.md            ← you are here
├── .gitignore           ← keeps fetched CS50 data + binaries OUT of git
├── shop-sample/         ← ORIGINAL synthetic dataset (committed; safe; works on every engine)
│   ├── customers.csv  products.csv  orders.csv
│   ├── schema.sql       ← canonical table shapes
│   └── README.md
├── cs50/
│   ├── fetch.sh         ← downloads the official CS50 dataset ZIPs FROM CS50 (not stored in git)
│   ├── downloads/       ← (gitignored) where fetch.sh puts the .zip / .db files
│   └── README.md        ← exercise catalog: our summaries + links to the official problems
└── loaders/             ← scripts to INJECT a dataset into each engine via Docker
    └── README.md
```

## Why CS50's data isn't committed here (and how you still get it)

CS50's *Introduction to Databases with SQL* is licensed
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/), but its problem **bundles
include third-party-licensed data** (e.g. IMDb, which has its own non-commercial terms). So this
repo does **not** redistribute their files. Instead:

- **`cs50/fetch.sh`** downloads the official ZIPs straight from CS50's CDN onto your machine
  (into `cs50/downloads/`, which is gitignored). The data comes from the source, on demand.
- **`cs50/README.md`** is an *original* catalog — our one-line summaries + links to each official
  problem page. Read the full task on CS50's site; nothing here is a copy of their prose.
- For something you can use **right now with zero downloads**, use **`shop-sample/`** — an original
  synthetic dataset (our shop schema) that the loaders can push into every engine.

## Quickstart

```bash
# 1. (optional) pull the official CS50 datasets from source:
bash playground/datas/cs50/fetch.sh            # → playground/datas/cs50/downloads/

# 2. load a dataset into an engine (examples — see loaders/README.md for all engines):
bash playground/datas/loaders/load-postgres.sh playground/datas/shop-sample   # CSV dir → Postgres
bash playground/datas/loaders/load-cs50-postgres.sh cs50/downloads/packages/packages.db  # whole .db → Postgres

# 3. open the engine and practice (see ../../wiki/database-cli/<engine>/00-connect.md):
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_shop'
```

Everything loads into a throwaway **`learn_shop`** database (or `learn-shop`/db-15 scratch namespace for
the non-SQL engines) so you never touch real grobase data — same convention as the
[engine guides](../../wiki/database-cli/README.md#practice-safely-these-are-live-backend-databases).

## How the pieces fit

| You want to… | Use |
|--------------|-----|
| Practice immediately on any engine | `shop-sample/` + `loaders/load-<engine>.sh` |
| Get the real CS50 datasets | `cs50/fetch.sh` |
| Know what each CS50 problem asks | `cs50/README.md` (+ official links) |
| Push a CS50 SQLite `.db` into Postgres whole | `loaders/load-cs50-postgres.sh` (pgloader) |
| Turn any SQLite `.db` into CSVs for any engine | `loaders/sqlite-to-csv.sh` |
| Learn the SQL behind it | [`wiki/database-cli/cs50-sql/`](../../wiki/database-cli/cs50-sql/README.md) |

---

*CS50 datasets/exercises © President and Fellows of Harvard College, CC BY-NC-SA 4.0 — fetched
from <https://cs50.harvard.edu/sql/>. The `shop-sample/` dataset is original to this repo.*
