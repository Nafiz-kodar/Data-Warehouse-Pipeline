# Naming Conventions

Rules used throughout this warehouse. They exist so that a name tells you which layer an object
belongs to, which source it came from, and what role it plays — without opening the DDL.

---

## General

- **`snake_case`** everywhere: lowercase, underscore-separated. Never quoted identifiers, never
  camelCase. Unquoted identifiers fold to lowercase in PostgreSQL, so mixed case invites bugs where
  `"myTable"` and `mytable` become different objects.
- **English** for all object names.
- **Never use SQL reserved words** as identifiers. The Bronze generator checks each source column
  against the reserved list and quotes only if unavoidable.
- **Singular attribute, plural collection**: a table holding many listings is `listings`;
  a column holding one name is `listing_name`.

---

## Schemas

| Schema | Contents |
|---|---|
| `bronze` | Raw landing zone. All columns `TEXT`, no transformation. |
| `silver` | Cleaned, typed, standardised — one table per source file. |
| `gold` | Business-ready star schema, exposed as views. |

---

## Table names

### Bronze and Silver — `<source_system>_<entity>`

Both layers preserve the source structure, so the prefix records **where the data came from**:

| Prefix | Source system |
|---|---|
| `summary_` | Inside Airbnb summary export |
| `detail_` | Inside Airbnb detailed export |
| `geo_` | GeoJSON boundary file |

Examples: `bronze.detail_listings`, `silver.summary_listings`, `bronze.geo_neighbourhoods_raw`.

> This mirrors the reference project's `crm_` / `erp_` split. The value is that
> `silver.detail_listings` announces its provenance — you never have to guess which export a column
> came from when the two disagree.

### Gold — `<type>_<entity>`

Gold is organised by **dimensional role**, not by source, because by this layer the sources have been
integrated and provenance is carried in columns rather than table names.

| Prefix | Role | Examples |
|---|---|---|
| `dim_` | Dimension | `dim_listing`, `dim_host`, `dim_neighbourhood`, `dim_amenity`, `dim_date` |
| `fact_` | Fact | `fact_listing_snapshot`, `fact_review` |
| `bridge_` | Many-to-many resolver | `bridge_listing_amenity` |

---

## Column names

### Keys

| Pattern | Meaning | Example |
|---|---|---|
| `<entity>_key` | **Surrogate** key, generated in Gold | `listing_key`, `host_key` |
| `<entity>_id` | **Natural** key, from the source system | `listing_id`, `host_id`, `review_id` |
| `<entity>_key` on a fact | Foreign key to that dimension | `fact_review.listing_key` |

The `_key` / `_id` distinction is load-bearing: `_key` values are regenerated on every reload and must
never be persisted outside the warehouse, while `_id` values are stable and safe for external joins.

### Booleans — `is_`, `has_`, or `<verb>_`

Always prefixed so a boolean reads as a predicate:

`is_freshly_scraped` · `is_detail_sourced` · `is_multi_listing_host` · `is_minimum_nights_outlier`
· `has_license` · `has_availability` · `has_unbounded_max_nights` · `geom_was_repaired`
· `bathrooms_is_derived`

### Transparency flags

Where Silver **changes or derives** a value, a companion boolean records that it did. This keeps
repairs auditable instead of invisible:

| Flag | Records |
|---|---|
| `bathrooms_is_derived` | `bathrooms` was parsed from `bathrooms_text` (D8) |
| `geom_was_repaired` | Polygon was fixed by `ST_MakeValid` (D15) |
| `has_unbounded_max_nights` | The `INT32_MAX` sentinel was replaced with NULL (D14) |
| `is_detail_sourced` | Row came from the detailed export rather than summary only (D5) |

### Measures

Plain descriptive names, with units or windows where ambiguity is possible:
`price_amount`, `area_sqkm`, `estimated_revenue_l365d`, `number_of_reviews_ltm`,
`availability_365`, `comment_length`.

Suffix glossary, inherited from the Inside Airbnb source: `_l365d` last 365 days · `_ltm` last twelve
months · `_l30d` last 30 days · `_ly` last year · `_ntm` next twelve months · `_eoy` end of year.

### Technical columns — `dwh_` prefix

Warehouse-generated metadata is prefixed so it can never collide with a source column:
`dwh_create_date`.

---

## Routines

| Pattern | Purpose | Example |
|---|---|---|
| `<layer>.load_<layer>()` | Truncate-and-reload procedure for that layer | `bronze.load_bronze()`, `silver.load_silver()` |

Gold has no load procedure: it is composed entirely of views (decision A5).

---

## Files

| Pattern | Purpose |
|---|---|
| `ddl_<layer>.sql` | Table or view definitions |
| `proc_load_<layer>.sql` | The load procedure |
| `quality_checks_<layer>.sql` | Assertion suite for that layer |
| `NN_<topic>.ipynb` | Notebooks, numbered in execution order |

---

## Defect identifiers

Data-quality issues are numbered `D1`–`D15` in [`cleaning_spec.md`](cleaning_spec.md) and that
identifier is cited wherever the issue is addressed — in DDL comments, in the load procedures, in the
quality checks, and in the data catalog. Any fix can therefore be traced from the register to the
exact SQL block that implements it and the assertion that proves it.
