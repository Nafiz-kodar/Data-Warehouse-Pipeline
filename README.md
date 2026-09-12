# Boston Short-Term Rental Data Warehouse

A medallion-architecture data warehouse built on **PostgreSQL 16 + PostGIS**, turning the raw Inside
Airbnb export for Boston into a query-ready dimensional model.

Structurally modelled on [DataWithBaraa/sql-data-warehouse-project](https://github.com/DataWithBaraa/sql-data-warehouse-project),
adapted from SQL Server to PostgreSQL and extended with spatial data.

```
CSV + GeoJSON  ──▶  BRONZE  ──▶  SILVER  ──▶  GOLD  ──▶  analysis
  6 files           raw,         cleaned,      star
  91 MB             all TEXT     typed,        schema
                                 integrated    (views)
```

**Rebuilds from nothing in ~6 seconds. 65 automated quality checks, all passing.**

---

## Why this exists

Inside Airbnb publishes raw scrapes, not analysis-ready data. This drop contains two overlapping
exports of the same city where neither is a superset of the other, money stored as `$347.40` text,
1,434 amenities packed into a JSON string, 13 entirely empty columns, 493 reviews pointing at
listings that do not exist, and a sentinel `2147483647` masquerading as a stay limit.

Every analyst who touches these files re-solves the same problems differently in a private notebook.
This project moves that work **once, into a database**, where it is versioned, reproducible by anyone
with a connection string, and tested.

---

## Quickstart

Requires Docker.

```bash
# 1. Start PostgreSQL + PostGIS (schemas are created automatically)
docker compose up -d

# 2. Build Bronze
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/ddl_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/proc_load_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL bronze.load_bronze();"

# 3. Build Silver
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/proc_load_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL silver.load_silver();"

# 4. Build Gold
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/gold/ddl_gold.sql

# 5. Verify — expect 65 PASS
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_gold.sql
```

Or run [`notebooks/02_data_preprocessing.ipynb`](notebooks/02_data_preprocessing.ipynb), which does
all of the above and then validates and charts the result.

**Connection:** `localhost:5432` · db `datawarehouse` · user `dwh` · password `dwh_local_dev`
(local development only; the port is bound to `127.0.0.1`).

---

## The model

```
                          dim_date
                          |       |
   dim_host ──────> fact_listing_snapshot <────── dim_neighbourhood
      │                (4,414)      ▲               (26 + PostGIS)
      └────────> dim_listing ───────┘                    ▲
                 (4,414)  │  └──────> fact_review ───────┘
                          │            (252,910)
              bridge_listing_amenity
                          │
                    dim_amenity (1,434)
```

`fact_listing_snapshot` is grained at **listing × scrape date**, so additional scrapes load alongside
with no schema change. `fact_review` is grained at one row per review.

Full column-level reference: [**docs/data_catalog.md**](docs/data_catalog.md).

---

## What the build found

Fifteen data defects, each measured rather than assumed, each fixed in versioned SQL, each proven by
an assertion. The full register is in [docs/cleaning_spec.md](docs/cleaning_spec.md). The four most
consequential:

| | Defect | Impact |
|---|---|---|
| **D14** | `2147483647` used as a "no maximum stay" sentinel | 9 rows (0.2%) skewed `AVG(maximum_nights)` from 665 to **4,415,317** |
| **D15** | 4 of 26 neighbourhood polygons self-intersect | `ST_Contains` would have returned wrong answers **without erroring** |
| **D5/D6** | 36 listings exist only in the summary export | Integrating both sources took `fact_review` from **493 orphan rows to zero** |
| **D1** | 846 listings carry data copied from an older scrape | They average **$146.89** vs **$370.77** — silently blending them understates every price |

D14 and D15 were invisible to file-level profiling. They only surfaced once the data was typed and
handed to PostGIS — which is the argument for doing transforms in the database rather than in pandas.

---

## Sample findings

```sql
-- Superhosts earn their badge
SELECT dh.host_is_superhost,
       round(avg(f.review_scores_rating), 3)      AS rating,
       round(avg(f.estimated_occupancy_l365d))    AS occupancy_days
FROM gold.fact_listing_snapshot f
JOIN gold.dim_host dh USING (host_key)
WHERE f.is_freshly_scraped
GROUP BY 1;
```

| superhost | rating | occupancy days |
|---|---|---|
| false | 4.658 | 67 |
| **true** | **4.854** | **127** |

Superhosts achieve **nearly double the occupancy**. And Boston's market is highly concentrated:
**83.7% of listings belong to multi-listing hosts** — 690 hosts controlling 3,651 listings.

---

## Repository layout

```
├── datasets/           raw source drop (6 files, 5 loaded)
├── docs/
│   ├── project_charter.md      motivation, defect register, architecture decisions
│   ├── data_catalog.md         column-level reference for Gold
│   ├── cleaning_spec.md        the Silver contract (generated by notebook 01)
│   ├── defect_register.csv     machine-readable defect list
│   └── naming_conventions.md
├── notebooks/
│   ├── 01_data_cleaning.ipynb        profiles the raw files, emits the cleaning spec
│   └── 02_data_preprocessing.ipynb   rebuilds, validates and visualises the warehouse
├── scripts/
│   ├── init_database.sql       schemas + PostGIS
│   ├── bronze/  ddl + load procedure
│   ├── silver/  ddl + load procedure
│   └── gold/    star-schema views
├── tests/       quality_checks_silver.sql (33) · quality_checks_gold.sql (32)
└── docker-compose.yml
```

---

## Design decisions

Recorded with rationale in [docs/project_charter.md](docs/project_charter.md §4). In brief:

| | Decision | Why |
|---|---|---|
| **A1** | PostgreSQL + PostGIS | Stored procedures preserve the reference project's structure; PostGIS handles the GeoJSON natively |
| **A2** | SQL owns every transform | The database rebuilds standalone. Notebooks execute and verify SQL, never reimplement it |
| **A3** | Bronze/Silver split by source system | Makes cross-source integration a real, testable step rather than an assumption |
| **A4** | 2 facts, 5 dimensions, 1 bridge | Conformed dimensions; the bridge models the amenity many-to-many properly |
| **A5** | Fact grain = listing × scrape date | Absorbs future scrapes with no redesign |

**Nothing in this warehouse is imputed.** 685 listings have no price and 901 have no review scores;
those stay NULL. A missing value is information, and inventing one destroys it.

---

## Limitations

Surrogate keys are regenerated on each reload — join on natural keys (`listing_id`, `host_id`) when
persisting results externally. `estimated_revenue_l365d` is Airbnb's model output, not observed
revenue. Only one scrape window is loaded, so no time trends can be computed from the snapshot fact.
Loading is full-refresh only; there is no CDC or incremental path.
