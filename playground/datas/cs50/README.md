# CS50 SQL — exercise catalog

An **original** index of CS50's *Introduction to Databases with SQL* problem sets: our one-line
summary of each task, a link to the **official problem page** (read the full instructions there —
we don't copy their prose), the dataset the fetcher pulls, and which lesson/engine concept it
exercises.

> **Get the data:** run [`./fetch.sh`](fetch.sh) — it downloads the official ZIPs from CS50's CDN
> into `./downloads/` (gitignored). Some problems are distributed only through the
> [cs50.dev](https://cs50.dev) codespace (`update50`) and will be skipped by the fetcher; for those,
> grab the data from the codespace or the problem page. **License:** CS50 materials are
> © Harvard, [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).

CS50's problems are written for **SQLite**. To run them on our server engines, convert/load with
the [`../loaders/`](../loaders/README.md) scripts. Each row below links the matching lesson notes in
[`wiki/database-cli/cs50-sql/`](../../../wiki/database-cli/cs50-sql/README.md).

## Problem Set 0 — Querying · [official](https://cs50.harvard.edu/sql/psets/0/) · notes: [lesson 0](../../../wiki/database-cli/cs50-sql/lesson-0-querying.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| Cyberchase | Answer questions about a TV-series episode database with `SELECT`/`WHERE`/`ORDER BY` | [link](https://cs50.harvard.edu/sql/psets/0/cyberchase/) | basic querying |
| 36 Views | Query a dataset of Hokusai print views (pick this or *Normals*) | [link](https://cs50.harvard.edu/sql/psets/0/views/) | filtering, ordering |
| Normals | Query a normal-distribution / stats dataset (alternative to *36 Views*) | [link](https://cs50.harvard.edu/sql/psets/0/normals/) | aggregates |
| Players | Query a baseball *players* dataset | [link](https://cs50.harvard.edu/sql/psets/0/players/) | `LIMIT`, `ORDER BY`, aggregates |

## Problem Set 1 — Relating · [official](https://cs50.harvard.edu/sql/psets/1/) · notes: [lesson 1](../../../wiki/database-cli/cs50-sql/lesson-1-relating.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| Packages, Please | Trace lost packages across related tables with `JOIN`s and subqueries | [link](https://cs50.harvard.edu/sql/psets/1/packages/) | joins, subqueries |
| DESE | Analyse a Massachusetts public-education dataset | [link](https://cs50.harvard.edu/sql/psets/1/dese/) | joins, grouping |
| Moneyball | Query a baseball-statistics database to find value players | [link](https://cs50.harvard.edu/sql/psets/1/moneyball/) | joins, `GROUP BY`, subqueries |

## Problem Set 2 — Designing · [official](https://cs50.harvard.edu/sql/psets/2/) · notes: [lesson 2](../../../wiki/database-cli/cs50-sql/lesson-2-designing.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| ATL | Design/normalise a schema for an Atlanta-themed dataset | [link](https://cs50.harvard.edu/sql/psets/2/atl/) | schema design, keys |
| Happy to Connect | Design a schema for a professional social network | [link](https://cs50.harvard.edu/sql/psets/2/connect/) | normalization, relationships |
| Union Square Donuts | Design tables for a bakery's orders | [link](https://cs50.harvard.edu/sql/psets/2/donuts/) | `CREATE TABLE`, constraints |

## Problem Set 3 — Writing · [official](https://cs50.harvard.edu/sql/psets/3/) · notes: [lesson 3](../../../wiki/database-cli/cs50-sql/lesson-3-writing.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| Meteorite Cleaning | Import a meteorite-landings CSV, then clean it (dedupe, round, null-handling) with `UPDATE`/`DELETE` | [link](https://cs50.harvard.edu/sql/psets/3/meteorites/) | CSV import, `INSERT`/`UPDATE`/`DELETE` |
| Don't Panic! | Write the data layer for a message-board app | [link](https://cs50.harvard.edu/sql/psets/3/dont-panic/) | writing data, triggers |

## Problem Set 4 — Viewing · [official](https://cs50.harvard.edu/sql/psets/4/) · notes: [lesson 4](../../../wiki/database-cli/cs50-sql/lesson-4-viewing.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| Census Taker | Build views over census data | [link](https://cs50.harvard.edu/sql/psets/4/census/) | `CREATE VIEW`, CTEs |
| The Private Eye | Use views/CTEs to decode a puzzle dataset | [link](https://cs50.harvard.edu/sql/psets/4/private/) | views, partitioning |
| Bed and Breakfast | Build views for a lodging dataset | [link](https://cs50.harvard.edu/sql/psets/4/bnb/) | views, securing data |

## Problem Set 5 — Optimizing · [official](https://cs50.harvard.edu/sql/psets/5/) · notes: [lesson 5](../../../wiki/database-cli/cs50-sql/lesson-5-optimizing.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| In a Snap | Speed up slow queries by adding the right indexes | [link](https://cs50.harvard.edu/sql/psets/5/snap/) | `CREATE INDEX`, `EXPLAIN` |
| your.harvard | Optimise course-catalog queries with indexes | [link](https://cs50.harvard.edu/sql/psets/5/your.harvard/) | indexes, query plans |

## Problem Set 6 — Scaling · [official](https://cs50.harvard.edu/sql/psets/6/) · notes: [lesson 6](../../../wiki/database-cli/cs50-sql/lesson-6-scaling.md)

| Problem | One-line goal (ours) | Official | Skills |
|---------|----------------------|----------|--------|
| Happy to Connect (Sentimental) | Re-implement the social network on a server DBMS | [link](https://cs50.harvard.edu/sql/psets/6/connect/) | MySQL/PostgreSQL |
| From the Deep | Query a sea-lion / sharks dataset at scale | [link](https://cs50.harvard.edu/sql/psets/6/deep/) | server engines, joins |
| Don't Panic! (Python / Java) | Drive the DB from application code with prepared statements | [Python](https://cs50.harvard.edu/sql/psets/6/dont-panic/python/) · [Java](https://cs50.harvard.edu/sql/psets/6/dont-panic/java/) | access control, SQL-injection safety |

---

*Summaries above are our own; for the exact task descriptions and rules, follow the official links.
Datasets © Harvard / their respective owners, fetched from <https://cs50.harvard.edu/sql/>.*
