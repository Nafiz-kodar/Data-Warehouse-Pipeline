# Operations Runbook

Procedures for running, rebuilding, connecting to and troubleshooting the warehouse.

All commands assume the repository root as the working directory.

---

## 1. Environment

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 20.10+ | Must be running before any command below |
| Docker Compose | v2 | Invoked as `docker compose`, not `docker-compose` |
| Python | 3.11+ | Required only for the notebooks |
| Free disk | ~1 GB | 235 MB database plus source files |

A local PostgreSQL client is **not** required. All SQL is executed through
`docker compose exec`, which uses the `psql` binary inside the container.

---

## 2. Starting and stopping

```bash
# Start (detached)
docker compose up -d

# Check health — expect "(healthy)"
docker compose ps

# Follow logs
docker compose logs -f postgres

# Stop, preserving all data
docker compose down

# Stop and DESTROY all warehouse data (source files are unaffected)
docker compose down -v
```

The named volume `dwh_pgdata` persists across `docker compose down`. Only `down -v` removes it.

### First-run initialisation

On the very first start with an empty volume, PostgreSQL executes
`scripts/init_database.sql` automatically through `/docker-entrypoint-initdb.d/`, creating the three
schemas and the PostGIS extension.

**This runs only once.** After editing `init_database.sql`, either re-run it manually (§4.1) or
destroy the volume with `docker compose down -v` and start again.

---

## 3. Building the warehouse

### 3.1 Full build

Run in order. Each layer depends on the one before it.

```bash
# Bronze — raw landing
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/ddl_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/bronze/proc_load_bronze.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL bronze.load_bronze();"

# Silver — cleaned and typed
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/proc_load_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL silver.load_silver();"

# Gold — star-schema views
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/gold/ddl_gold.sql
```

Expected output from the load procedures:

```
NOTICE:  >> [Detail] bronze.detail_reviews
NOTICE:     252910 rows in 00:00:00.684934
NOTICE:  Bronze load complete in 00:00:00.949255
```

### 3.2 Reload data without recreating structures

Once the DDL and procedures exist, a data refresh needs only the two `CALL` statements:

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse \
  -c "CALL bronze.load_bronze();" -c "CALL silver.load_silver();"
```

Gold requires no action — the views are current with Silver by construction.

### 3.3 Rebuild a single layer

Because every script drops and recreates its objects, any layer can be rebuilt independently,
provided the layers below it are populated.

```bash
# Silver only
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < scripts/silver/proc_load_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "CALL silver.load_silver();"
```

Rebuilding Silver drops the Gold views through `CASCADE`. Re-apply `ddl_gold.sql` afterwards.

### 3.4 Complete rebuild from zero

```bash
docker compose down -v && docker compose up -d
sleep 15                      # wait for initialisation
# then run §3.1 in full
```

Alternatively, run [`notebooks/02_data_preprocessing.ipynb`](../notebooks/02_data_preprocessing.ipynb),
which performs a full teardown and rebuild, then validates and charts the result.

---

## 4. Common tasks

### 4.1 Re-run database initialisation

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse \
  -f /docker-entrypoint-initdb.d/01_init_database.sql
```

The script is idempotent, so this is always safe.

### 4.2 Inspect the schema

```bash
# List objects in a schema
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "\dt silver.*"
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "\dv gold.*"

# Describe one object
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "\d+ gold.fact_listing_snapshot"

# Row counts across all layers
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname IN ('bronze','silver')
ORDER BY 1,2;"
```

### 4.3 Open an interactive session

```bash
docker compose exec -it postgres psql -U dwh -d datawarehouse
```

### 4.4 Check database size

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse -c "
SELECT pg_size_pretty(pg_database_size('datawarehouse')) AS total,
       pg_size_pretty(pg_total_relation_size('silver.detail_reviews')) AS reviews;"
```

---

## 5. Verification

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_silver.sql
docker compose exec -T postgres psql -U dwh -d datawarehouse < tests/quality_checks_gold.sql
```

Each suite returns one row per assertion. All 65 should read `PASS`.

To show only failures:

```bash
docker compose exec -T postgres psql -U dwh -d datawarehouse \
  < tests/quality_checks_gold.sql | grep FAIL
```

An empty result means every assertion passed.

### Interpreting a failure

Each row reports `actual` against `expected`. Locate the `check_id` in the suite file to see the
query, then trace the defect identifier (`D1`–`D15`) to its implementing block in
`proc_load_silver.sql` or `ddl_gold.sql`.

| Failing check | Likely cause |
|---|---|
| `S01`–`S05` (row counts) | A load procedure did not complete, or source files changed |
| `S10`–`S28` (defect resolution) | A cleaning rule was modified or removed |
| `G01`–`G07` (cardinality) | Silver is stale relative to Gold, or integration logic changed |
| `G17`–`G22` (referential) | Integration failed; orphan foreign keys reintroduced |
| `G29` (spatial) | Geometry repair or coordinate data altered |

Expected counts are asserted against the values measured in
[`cleaning_spec.md`](cleaning_spec.md). If source files are replaced with a newer scrape, these
counts will legitimately change and the suites must be updated.

---

## 6. Connecting

### 6.1 Connection parameters

| Parameter | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `5432` |
| Database | `datawarehouse` |
| User | `dwh` |
| Password | `dwh_local_dev` |

### 6.2 VS Code

Install the **PostgreSQL** extension (`ms-ossdata.vscode-pgsql`) or **SQLTools**
(`mtxr.sqltools`) with its PostgreSQL driver, then add a connection using the parameters above.

Opening any `.sql` file and pressing `Cmd+Enter` / `Ctrl+Enter` executes it with results in an inline
grid. `RAISE NOTICE` output from the load procedures appears in the output panel, so
`CALL silver.load_silver();` can be run and monitored directly from the editor.

### 6.3 Python

```python
from sqlalchemy import create_engine
import pandas as pd

engine = create_engine(
    "postgresql+psycopg://dwh:dwh_local_dev@127.0.0.1:5432/datawarehouse")

df = pd.read_sql("SELECT * FROM gold.dim_neighbourhood", engine)
```

### 6.4 Notebooks

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install pandas matplotlib jupyter nbformat pyarrow jupysql sqlalchemy "psycopg[binary]"
jupyter notebook
```

Inside a notebook:

```python
%load_ext sql
%config SqlMagic.autopandas = True
%sql postgresql+psycopg://dwh:dwh_local_dev@127.0.0.1:5432/datawarehouse
```

`%%sql` cells then execute inside PostgreSQL and return DataFrames.

---

## 7. Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker is not running | Start Docker Desktop, then retry |
| `psql: could not connect to server` | Container still initialising | `docker compose ps` and wait for `(healthy)` |
| `port 5432 already allocated` | Another PostgreSQL instance is bound to the port | Stop it, or change the host port in `docker-compose.yml` to `5433:5432` |
| `schema "bronze" does not exist` | Volume pre-existed the init script | Run §4.1, or `docker compose down -v` and start again |
| `could not open file "/datasets/…"` | Volume mount missing or path changed | Confirm the `./datasets:/datasets:ro` mount in `docker-compose.yml` |
| `permission denied for function pg_read_file` | Connected as a non-superuser | Connect as `dwh`, which is superuser by default |
| `relation "silver.…" does not exist` | Silver DDL not applied | Run `ddl_silver.sql` before the load procedure |
| Gold views vanish after a Silver rebuild | `DROP TABLE … CASCADE` removed dependents | Re-apply `scripts/gold/ddl_gold.sql` |
| `numeric field overflow` | A source value exceeds the declared precision | Inspect the source column; widen the type in `ddl_silver.sql` |
| Load succeeds but counts are wrong | Source files changed | Re-run the profiling notebook and update the expected values in `tests/` |
| `platform mismatch` warning on start | PostGIS image is x86-64; host is ARM | Harmless. Runs under emulation; full rebuild still completes in ~6 s |

### Inspecting a failed load

Load procedures roll back entirely on failure, so a failed layer retains its previous contents. The
error is reported before being re-raised:

```
NOTICE:  !! SILVER LOAD FAILED: numeric field overflow (SQLSTATE 22003)
```

To locate the offending record, query Bronze directly — it is untyped, so the raw value is intact:

```sql
SELECT id, maximum_nights
FROM   bronze.detail_listings
WHERE  maximum_nights !~ '^[0-9]*$';
```

---

## 8. Backup and restore

```bash
# Full logical backup
docker compose exec -T postgres pg_dump -U dwh -d datawarehouse -Fc > warehouse.dump

# Schema only
docker compose exec -T postgres pg_dump -U dwh -d datawarehouse --schema-only > schema.sql

# Restore
docker compose exec -T postgres pg_restore -U dwh -d datawarehouse --clean < warehouse.dump
```

Backups are largely unnecessary here: the warehouse is fully derivable from the source files in
`datasets/` in approximately six seconds. Rebuilding is faster and more reliable than restoring.

---

## 9. Loading a new source extract

When Inside Airbnb publishes a newer scrape:

1. **Profile it first.** Run [`notebooks/01_data_cleaning.ipynb`](../notebooks/01_data_cleaning.ipynb)
   against the new files. It regenerates `cleaning_spec.md` and `defect_register.csv` with measured
   counts, revealing whether existing defects persist or new ones have appeared.
2. **Check the column set.** `bronze.load_bronze()` lists columns explicitly in each `COPY`. Added or
   removed source columns require regenerating `ddl_bronze.sql`.
3. **Update expected counts** in `tests/quality_checks_*.sql` to match the new measurements.
4. **Decide on history.** To retain the previous scrape rather than replace it, see
   [data_architecture.md](data_architecture.md) §8.1 — the fact grain already supports it.
5. **Rebuild and verify** per §3.1 and §5.

---

## 10. Maintenance notes

- **`.venv` is excluded from version control** by `.gitignore`. It is approximately 607 MB and must
  never be committed.
- **Credentials in `docker-compose.yml` are non-secret development values**, committed deliberately
  so the environment is reproducible. Override them via `docker-compose.override.yml` or `.env`,
  both of which are gitignored. They are unsuitable for any shared deployment.
- **Generated documentation** — `cleaning_spec.md` and `defect_register.csv` — is produced by
  notebook 01. Edit the notebook, not the outputs.
- **Bronze is not for analysis.** Query Gold. Bronze exists for lineage and reload; Silver is an
  intermediate.
