# Boston Short-Term Rental Data Warehouse

A production-style analytical data warehouse built on PostgreSQL 16 and PostGIS, implementing the
medallion architecture (Bronze → Silver → Gold) over the Inside Airbnb public dataset for Boston,
Massachusetts.

| | |
|---|---|
| **Engine** | PostgreSQL 16.4 · PostGIS 3.4 (Docker) |
| **Architecture** | Medallion — Bronze (raw) → Silver (cleaned) → Gold (dimensional) |
| **Source data** | Inside Airbnb, Boston MA · scrape window 2026-06-15 → 2026-07-06 |
| **Model** | Star schema — 2 fact tables, 5 dimensions, 1 bridge |
| **Volume** | 4,414 listings · 252,910 reviews · 155,233 listing-amenity pairs |
| **Quality gates** | 65 automated assertions (33 Silver, 32 Gold) — all passing |
| **Rebuild time** | ~6 seconds from an empty database |

This project is structurally modelled on
[DataWithBaraa/sql-data-warehouse-project](https://github.com/DataWithBaraa/sql-data-warehouse-project),
adapted from SQL Server to PostgreSQL and extended with spatial capability.

---

## Table of contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Data model](#data-model)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Data quality](#data-quality)
- [Testing](#testing)
- [Repository structure](#repository-structure)
- [Documentation](#documentation)
- [Design decisions](#design-decisions)
- [Performance](#performance)
- [Limitations](#limitations)
- [License](#license)

---

## Overview

### Problem

Inside Airbnb distributes raw web-scrape output rather than analysis-ready data. The Boston drop
presents several structural obstacles to direct analysis:

- **Two overlapping exports.** A 19-column summary file and a 90-column detailed file describe the
  same market, but neither is a superset of the other. The summary contains 36 listings absent from
  the detailed file; the detailed file contains all remaining attributes.
- **Type-unsafe encoding.** Prices are stored as text (`$347.40`), booleans as `'t'`/`'f'`, and
  amenities as a JSON array embedded in a string column.
- **Uninformative columns.** Thirteen of the 90 detailed columns are entirely NULL.
- **Referential breakage.** 493 review records reference listings that do not exist in the detailed
  export.
- **Sentinel values.** `2147483647` is used to denote "no maximum stay", and four of the 26
  neighbourhood polygons are geometrically invalid.

Each analyst working from these files resolves the same problems independently, in ways that are
neither versioned nor reproducible.

### Solution

This warehouse performs that remediation once, inside the database, where it is version-controlled,
executable by anyone with a connection string, and verified by an automated test suite. The output is
a dimensional model that answers market-analysis questions without reference to the raw files.

### Scope

**In scope:** ingestion of the listings, reviews and neighbourhood-boundary files; resolution of 15
catalogued data defects; cross-source integration; a star-schema presentation layer; spatial
enrichment via PostGIS; automated quality assurance.

**Out of scope:** incremental or change-data-capture loading (the pipeline is full-refresh);
the Inside Airbnb calendar and pricing-by-date files, which are not part of this drop; natural-language
processing of review text (the column is warehoused but unanalysed); business-intelligence tooling.

---

## Architecture

### Medallion layers

| Layer | Materialisation | Responsibility | Objects |
|---|---|---|---|
| **Bronze** | Tables, all columns `TEXT` | Byte-faithful landing zone. No transformation, so a load can never fail on a type error and raw forms remain inspectable for audit. | 5 tables · 118 columns |
| **Silver** | Typed tables | Cleaning, type casting, standardisation and derivation. Structure remains 1:1 with the source systems, so every table traces to exactly one source file. | 5 tables · 116 columns · 11 indexes |
| **Gold** | Views | Business-ready star schema. Cross-source integration and surrogate-key assignment occur here. | 8 views · 98 columns |

### Pipeline

```mermaid
flowchart LR
    subgraph SRC["Source files"]
        direction TB
        S1["listings_summary.csv<br/>4,414 × 19"]
        S2["listings_detailed.csv<br/>4,378 × 90"]
        S3["reviews_detailed.csv<br/>252,910 × 6"]
        S4["neighbourhoods.csv<br/>+ .geojson"]
    end

    subgraph BRZ["BRONZE — raw"]
        direction TB
        B1["summary_listings"]
        B2["detail_listings"]
        B3["detail_reviews"]
        B4["neighbourhoods<br/>geo_neighbourhoods_raw"]
    end

    subgraph SLV["SILVER — cleaned"]
        direction TB
        V1["summary_listings"]
        V2["detail_listings"]
        V3["detail_reviews"]
        V4["neighbourhoods (PostGIS)"]
        V5["detail_listing_amenity"]
    end

    subgraph GLD["GOLD — star schema"]
        direction TB
        G1["dim_listing · dim_host<br/>dim_neighbourhood<br/>dim_amenity · dim_date"]
        G2["fact_listing_snapshot<br/>fact_review"]
        G3["bridge_listing_amenity"]
    end

    SRC -->|"COPY<br/>load_bronze()"| BRZ
    BRZ -->|"cast, clean, derive<br/>load_silver()"| SLV
    SLV -->|"integrate, key<br/>ddl_gold.sql"| GLD
    GLD --> OUT["SQL · notebooks · BI"]
```

A `reviews_summary.csv` file is present in the source drop but deliberately not ingested: its
`(listing_id, date)` multiset is provably identical to `reviews_detailed.csv`, so it contributes no
information.

### Defect resolution by layer

Twelve of the fifteen catalogued defects are resolved in Silver. Three require both source systems to
be joined and are therefore resolved in Gold.

| Layer | Defects resolved |
|---|---|
| Silver | D1, D2, D4, D7, D8, D9, D10, D11, D12, D13, D14, D15 |
| Gold | D3 (price precedence), D5 (summary-only listings), D6 (orphan review keys) |

---

## Data model

### Star schema

```mermaid
erDiagram
    DIM_DATE            ||--o{ FACT_LISTING_SNAPSHOT : scrape_date_key
    DIM_DATE            ||--o{ FACT_REVIEW           : review_date_key
    DIM_LISTING         ||--o{ FACT_LISTING_SNAPSHOT : listing_key
    DIM_LISTING         ||--o{ FACT_REVIEW           : listing_key
    DIM_HOST            ||--o{ FACT_LISTING_SNAPSHOT : host_key
    DIM_NEIGHBOURHOOD   ||--o{ FACT_LISTING_SNAPSHOT : neighbourhood_key
    DIM_LISTING         ||--o{ BRIDGE_LISTING_AMENITY: listing_key
    DIM_AMENITY         ||--o{ BRIDGE_LISTING_AMENITY: amenity_key

    DIM_LISTING {
        bigint  listing_key PK
        bigint  listing_id  UK
        text    neighbourhood
        text    room_type
        boolean is_freshly_scraped
        boolean is_detail_sourced
    }
    DIM_HOST {
        bigint  host_key PK
        bigint  host_id  UK
        boolean host_is_superhost
        boolean is_multi_listing_host
    }
    DIM_NEIGHBOURHOOD {
        bigint   neighbourhood_key PK
        text     neighbourhood UK
        geometry geom
        numeric  area_sqkm
    }
    DIM_AMENITY {
        bigint amenity_key PK
        text   amenity UK
        bigint listing_count
    }
    DIM_DATE {
        int     date_key PK
        date    full_date
        boolean is_unknown_member
    }
    FACT_LISTING_SNAPSHOT {
        bigint  listing_key FK
        int     scrape_date_key FK
        bigint  host_key FK
        bigint  neighbourhood_key FK
        numeric price_amount
        numeric estimated_revenue_l365d
        numeric review_scores_rating
    }
    FACT_REVIEW {
        bigint review_id PK
        bigint listing_key FK
        int    review_date_key FK
        bigint reviewer_id
        text   comments
    }
    BRIDGE_LISTING_AMENITY {
        bigint listing_key FK
        bigint amenity_key FK
    }
```

### Object reference

| Object | Rows | Grain |
|---|---:|---|
| `gold.dim_listing` | 4,414 | One row per listing (integrated union of both sources) |
| `gold.dim_host` | 1,406 | One row per host |
| `gold.dim_neighbourhood` | 26 | One row per Boston neighbourhood, with validated MultiPolygon |
| `gold.dim_amenity` | 1,434 | One row per distinct amenity |
| `gold.dim_date` | 6,516 | One row per day, 2009-03-01 → 2026-12-31, plus one Unknown member |
| `gold.fact_listing_snapshot` | 4,414 | One row per listing per scrape date |
| `gold.fact_review` | 252,910 | One row per review |
| `gold.bridge_listing_amenity` | 155,233 | One row per listing-amenity pair |

The snapshot fact is grained at listing × scrape date rather than listing alone. Today this yields one
row per listing, but the model accommodates subsequent scrapes without schema change.

Complete column-level documentation is provided in [docs/data_catalog.md](docs/data_catalog.md).

---

## Prerequisites

| Requirement | Version | Purpose |
|---|---|---|
| Docker | 20.10 or later | Runs PostgreSQL and PostGIS |
| Docker Compose | v2 | Orchestration |
| Python | 3.11 or later | Notebooks only; the warehouse itself has no Python dependency |

Approximately 1 GB of free disk space is required: 235 MB for the database, plus the source files.

---

## Installation

### 1. Start the database

```bash
docker compose up -d
```

PostgreSQL initialises with the `bronze`, `silver` and `gold` schemas and the PostGIS extension
already created, via `scripts/init_database.sql`. Confirm readiness:

```bash
docker compose ps          # expect: dwh_postgres ... (healthy)
```

### 2. Build the layers

```bash
# Bronze
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/ddl_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/proc_load_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL bronze.load_bronze();"

# Silver
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/proc_load_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL silver.load_silver();"

# Gold
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/gold/ddl_gold.sql
```

Each load procedure emits per-table row counts and timings through `RAISE NOTICE`.

### 3. Verify

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_gold.sql
```

Both suites return one row per assertion with a `PASS` or `FAIL` result. All 65 assertions are
expected to pass.

### 4. Optional — Python environment for the notebooks

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install pandas matplotlib jupyter nbformat pyarrow jupysql sqlalchemy "psycopg[binary]"
```

Operational procedures, including full rebuild and troubleshooting, are documented in
[docs/operations.md](docs/operations.md).

---

## Usage

### Connection parameters

| Parameter | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `5432` |
| Database | `datawarehouse` |
| User | `dwh` |
| Password | `dwh_local_dev` |

These credentials are for local development only. The port is bound to the loopback interface, so
the database is not reachable from other hosts.

**SQLAlchemy URI:** `postgresql+psycopg://dwh:dwh_local_dev@127.0.0.1:5432/datawarehouse`

### Query semantics

Two conventions govern correct use of this warehouse.

**Filter on `is_freshly_scraped` when aggregating measures.** 846 listings (19.3% of the total) carry
values copied forward from an earlier scrape rather than observed in the current one. These average
$146.89 against $370.77 for freshly scraped listings. Including them without intent understates
every price and availability aggregate.

**NULL denotes "not known", never zero.** No value in this warehouse is imputed. 901 listings have no
reviews and therefore carry NULL review scores; 685 have no recorded price; `maximum_nights` is NULL
where the stay is unbounded. Use aggregate functions such as `avg()`, which exclude NULLs, rather
than substituting zero.

### Example — price and rating by neighbourhood

```sql
SELECT dn.neighbourhood,
       count(*)                                   AS listings,
       round(avg(f.price_amount), 2)              AS avg_price,
       round(avg(f.review_scores_rating), 3)      AS avg_rating,
       round(avg(f.estimated_revenue_l365d))      AS avg_revenue
FROM   gold.fact_listing_snapshot f
JOIN   gold.dim_neighbourhood dn USING (neighbourhood_key)
WHERE  f.is_freshly_scraped
GROUP  BY 1
HAVING count(*) >= 40
ORDER  BY avg_revenue DESC;
```

### Example — superhost performance

```sql
SELECT dh.host_is_superhost,
       count(*)                                   AS listings,
       round(avg(f.review_scores_rating), 3)      AS avg_rating,
       round(avg(f.estimated_occupancy_l365d))    AS avg_occupancy_days
FROM   gold.fact_listing_snapshot f
JOIN   gold.dim_host dh USING (host_key)
WHERE  f.is_freshly_scraped
GROUP  BY 1;
```

| host_is_superhost | listings | avg_rating | avg_occupancy_days |
|---|---:|---:|---:|
| false | 2,104 | 4.658 | 67 |
| true | 1,428 | 4.854 | 127 |

### Example — amenities via the bridge

```sql
SELECT da.amenity,
       count(*)                        AS listings,
       round(avg(f.price_amount), 2)   AS avg_price
FROM   gold.bridge_listing_amenity b
JOIN   gold.dim_amenity da            USING (amenity_key)
JOIN   gold.fact_listing_snapshot f   USING (listing_key)
WHERE  f.is_freshly_scraped
GROUP  BY 1
HAVING count(*) >= 150
ORDER  BY avg_price DESC;
```

Joining a fact through the bridge multiplies fact rows by the number of amenities per listing.
Aggregate the fact before bridging, or restrict aggregation to averages and counts.

### Example — spatial query

```sql
-- Listings within 1 km of Boston Common
SELECT dl.listing_id, dl.listing_name, dl.neighbourhood
FROM   gold.dim_listing dl
WHERE  ST_DWithin(
           ST_SetSRID(ST_MakePoint(dl.longitude, dl.latitude), 4326)::geography,
           ST_SetSRID(ST_MakePoint(-71.0656, 42.3550), 4326)::geography,
           1000);
```

---

## Data quality

Fifteen defects were catalogued, each quantified against the source data rather than assumed, each
resolved in versioned SQL, and each verified by an assertion. The complete register with measured
counts is in [docs/cleaning_spec.md](docs/cleaning_spec.md) and, in machine-readable form, in
[docs/defect_register.csv](docs/defect_register.csv).

### Summary

| ID | Defect | Measured | Resolution |
|---|---|---|---|
| D1 | Three scrape dates, not one snapshot | 628 / 2,904 / 846 | Retained as `scrape_date`; `source` promoted to `listing_source` |
| D2 | Price stored as text with currency symbols | 3,693 values | Cast to `numeric(10,2)` |
| D3 | Price disagrees between sources | 2,300 of 3,693 | Detailed source takes precedence |
| D4 | Price missing | 685 listings | Retained as NULL; never imputed |
| D5 | Listings present only in the summary export | 36 listings | `LEFT JOIN` integration in Gold |
| D6 | Orphan review foreign keys | 23 listings / 493 rows | Resolved by D5 integration |
| D7 | Amenities encoded as a JSON array | 1,434 distinct / 155,233 pairs | Exploded to a bridge table |
| D8 | `bathrooms` NULL though text present | 1,030 recoverable | Parsed from `bathrooms_text` |
| D9 | Columns entirely NULL | 13 of 90 | Not carried into Silver |
| D10 | `neighbourhood_group` unused | All rows blank | Dropped |
| D11 | Listings with no reviews | 901 listings | NULL scores retained, not zero-filled |
| D12 | `minimum_nights` outlier | 1 listing at 400 nights | Value retained, flagged |
| D13 | Booleans encoded as `'t'`/`'f'` | 4 columns | Cast to native `boolean` |
| D14 | `INT32_MAX` sentinel for "no maximum stay" | 9 listings | Converted to NULL, flagged |
| D15 | Self-intersecting polygons | 4 of 26 | Repaired with `ST_MakeValid`, flagged |

### Defects requiring the database to detect

D14 and D15 were not identifiable from file-level profiling. Both surfaced only after the data had
been typed and passed to PostGIS:

- **D14.** Nine rows out of 4,378 (0.2%) carried `2147483647` in `maximum_nights`. Left in place, this
  shifts `AVG(maximum_nights)` from 665 to 4,415,317 — a factor of approximately 6,600.
- **D15.** Four neighbourhood polygons self-intersect. `ST_Contains` against an invalid geometry
  returns incorrect results without raising an error, so every spatial join would have been silently
  wrong.

Both are flagged rather than silently corrected: `has_unbounded_max_nights` and `geom_was_repaired`
record that an intervention occurred, keeping the repair auditable.

---

## Testing

Two assertion suites, executable from `psql` or loadable directly into a DataFrame.

| Suite | Assertions | Coverage |
|---|---:|---|
| [`tests/quality_checks_silver.sql`](tests/quality_checks_silver.sql) | 33 | Row-count preservation, key uniqueness, per-defect resolution, referential integrity, date-range sanity |
| [`tests/quality_checks_gold.sql`](tests/quality_checks_gold.sql) | 32 | Dimension and fact cardinality, surrogate-key uniqueness, declared grains, foreign-key resolution, integration outcomes, spatial containment, measure bounds |

Each assertion returns `check_id`, `description`, `actual`, `expected` and `result`. A representative
example:

```
 check_id |                       description                        | actual | expected | result
----------+----------------------------------------------------------+--------+----------+--------
 G23      | D5: 36 summary-only listings survived integration        |     36 |       36 | PASS
 G29      | O4: every listing falls inside its neighbourhood polygon |      0 |        0 | PASS
```

Check `G29` verifies that all 4,414 listings fall within the boundary of their assigned neighbourhood
using `ST_Contains`. It validates the coordinate data and the D15 geometry repair simultaneously, and
would fail if either were incorrect.

---

## Repository structure

```
.
├── datasets/                          Source drop — 6 files, 5 ingested
│   ├── listings_summary.csv           4,414 × 19
│   ├── listings_detailed.csv          4,378 × 90
│   ├── reviews_detailed.csv           252,910 × 6
│   ├── reviews_summary.csv            Not ingested — proven redundant
│   ├── neighbourhoods.csv             26 × 2
│   └── neighbourhoods.geojson         26 MultiPolygon features
│
├── docs/
│   ├── project_charter.md             Motivation, defect register, architecture decisions
│   ├── data_architecture.md           Layer design, lineage, load strategy
│   ├── data_catalog.md                Column-level reference for Gold
│   ├── data_model.md                  Star-schema design rationale
│   ├── operations.md                  Runbook and troubleshooting
│   ├── naming_conventions.md          Object and column naming rules
│   ├── cleaning_spec.md               Silver-layer contract (generated)
│   └── defect_register.csv            Machine-readable defect list (generated)
│
├── notebooks/
│   ├── 01_data_cleaning.ipynb         Source profiling; emits the cleaning specification
│   └── 02_data_preprocessing.ipynb    Rebuilds, validates and visualises the warehouse
│
├── scripts/
│   ├── init_database.sql              Schemas and PostGIS extension
│   ├── bronze/
│   │   ├── ddl_bronze.sql             5 landing tables, all columns TEXT
│   │   └── proc_load_bronze.sql       bronze.load_bronze()
│   ├── silver/
│   │   ├── ddl_silver.sql             5 typed tables, 11 indexes
│   │   └── proc_load_silver.sql       silver.load_silver()
│   └── gold/
│       └── ddl_gold.sql               8 star-schema views
│
├── tests/
│   ├── quality_checks_silver.sql      33 assertions
│   └── quality_checks_gold.sql        32 assertions
│
├── docker-compose.yml                 PostgreSQL 16 + PostGIS 3.4
└── README.md
```

---

## Documentation

| Document | Purpose |
|---|---|
| [docs/project_charter.md](docs/project_charter.md) | Project motivation, objectives, source observations, architecture decisions with rationale, success criteria |
| [docs/data_architecture.md](docs/data_architecture.md) | Layer responsibilities, lineage, load strategy, technology selection |
| [docs/data_model.md](docs/data_model.md) | Dimensional design: grain declarations, key strategy, bridge handling, unknown-member treatment |
| [docs/data_catalog.md](docs/data_catalog.md) | Column-level reference for every Gold object; Silver and Bronze summarised |
| [docs/operations.md](docs/operations.md) | Runbook: starting, rebuilding, connecting, troubleshooting, backup |
| [docs/naming_conventions.md](docs/naming_conventions.md) | Naming rules for schemas, tables, columns, routines and files |
| [docs/cleaning_spec.md](docs/cleaning_spec.md) | The Silver-layer contract, generated from measured source data |

---

## Design decisions

Recorded with full rationale in [docs/project_charter.md](docs/project_charter.md) §4.

| ID | Decision | Rationale |
|---|---|---|
| **A1** | PostgreSQL 16 with PostGIS | Native stored procedures preserve the reference architecture's structure; PostGIS handles GeoJSON ingestion and spatial validation without external tooling |
| **A2** | SQL is the authoritative transform engine | The database rebuilds independently of any Python environment. Notebooks execute and verify SQL but never reimplement it, so transformation logic exists in exactly one place |
| **A3** | Bronze and Silver partitioned by source system | Makes cross-source integration an explicit, testable step rather than an assumption, and keeps every Silver table traceable to one source file |
| **A4** | Two facts, five dimensions, one bridge | Conformed dimensions support both facts; the bridge models the listing-amenity many-to-many relationship without denormalisation |
| **A5** | Snapshot fact grained at listing × scrape date | Accommodates subsequent scrapes without redesign |

### Transformation placement

PostgreSQL performs natively every transformation that might otherwise justify a Python
implementation: `jsonb_array_elements_text` for the amenities array, `regexp_match` for bathroom-text
parsing, and PostGIS `ST_Contains` for spatial joins. Implementing these in pandas would place
transformation lineage outside the warehouse, make rebuilds dependent on notebook cell-execution
order, and reduce the medallion layers to a naming convention.

---

## Performance

Measured on Apple Silicon under x86-64 emulation, which is the slower configuration.

| Operation | Duration |
|---|---|
| `bronze.load_bronze()` | 0.95 s |
| `silver.load_silver()` | 4.17 s |
| Gold view creation | < 0.1 s |
| Full rebuild from an empty database | ~6 s |
| Database size when loaded | 235 MB |

The largest single operation is loading 252,910 review records into Bronze, which completes in
approximately 0.7 seconds via server-side `COPY`.

---

## Limitations

1. **Surrogate keys are not stable across reloads.** Gold generates them with `ROW_NUMBER()`, matching
   the reference architecture. Join on natural keys (`listing_id`, `host_id`) when persisting results
   outside the warehouse.
2. **`estimated_revenue_l365d` and `estimated_occupancy_l365d` are Airbnb model outputs**, not
   observed figures. They are indicators, not accounting values.
3. **A single scrape window is loaded.** The snapshot fact supports historical grain, but only
   2026-06-15 → 2026-07-06 is present, so no time series can be derived from it. Review history,
   by contrast, spans 2009-03-21 → 2026-07-04.
4. **Loading is full-refresh only.** Both procedures truncate and rebuild; there is no incremental or
   change-data-capture path.
5. **Gold is view-based.** Queries recompute surrogate keys on each execution and cannot use indexes
   on Gold objects directly, though the underlying Silver indexes are used.
6. **Review text is stored but unanalysed.** 252,910 review bodies are available in
   `gold.fact_review.comments`; no sentiment or topic modelling is applied.

---

## Technology stack

| Component | Version | Role |
|---|---|---|
| PostgreSQL | 16.4 | Warehouse engine; stored procedures, views |
| PostGIS | 3.4 | Geometry storage, validation and spatial predicates |
| Docker Compose | v2 | Environment provisioning |
| Python | 3.14 | Notebook runtime |
| pandas | 3.0 | Source profiling and result presentation |
| JupySQL | current | In-notebook SQL execution against PostgreSQL |
| psycopg | 3.3 | PostgreSQL driver |
| matplotlib | 3.11 | Visualisation, including the PostGIS choropleth |

---

## Data source and attribution

Source data is published by [Inside Airbnb](http://insideairbnb.com/), an independent, non-commercial
project that compiles publicly available information from Airbnb listings. Licensing terms for the
data are stated on the Inside Airbnb website; consult
[insideairbnb.com/get-the-data](http://insideairbnb.com/get-the-data/) before redistributing the
contents of `datasets/`.

The MIT License below covers the code in this repository, not the source data.

Architectural reference:
[DataWithBaraa/sql-data-warehouse-project](https://github.com/DataWithBaraa/sql-data-warehouse-project).

---

## License

Released under the MIT License. See [LICENSE](LICENSE).
