/*
===============================================================================
Initialise Database — schemas and extensions
===============================================================================
Purpose:
    Creates the three medallion schemas and the PostGIS extension inside the
    'datawarehouse' database.

Note on the reference project:
    The reference runs DROP DATABASE / CREATE DATABASE here. Under Docker the
    database itself is created by the POSTGRES_DB environment variable, and a
    session cannot drop the database it is connected to. To start completely
    fresh, destroy the volume instead:

        docker compose down -v && docker compose up -d

    This script is idempotent, so it is safe to run again by hand:

        docker compose exec -T postgres \
            psql -U dwh -d datawarehouse -f /docker-entrypoint-initdb.d/01_init_database.sql
===============================================================================
*/

-- PostGIS backs dim_neighbourhood's polygon column and the ST_Contains spatial
-- join used to validate listing coordinates against neighbourhood boundaries.
CREATE EXTENSION IF NOT EXISTS postgis;

-- Bronze: raw landing zone. Everything TEXT, nothing transformed.
CREATE SCHEMA IF NOT EXISTS bronze;

-- Silver: cleaned, typed, standardised, integrated across both source systems.
CREATE SCHEMA IF NOT EXISTS silver;

-- Gold: business-ready star schema, exposed as views.
CREATE SCHEMA IF NOT EXISTS gold;

COMMENT ON SCHEMA bronze IS 'Raw landing zone — byte-faithful copy of the source drop, all columns TEXT.';
COMMENT ON SCHEMA silver IS 'Cleaned and integrated layer — defects D1-D13 resolved here.';
COMMENT ON SCHEMA gold   IS 'Business-ready star schema — 2 facts, 5 dimensions, 1 bridge.';

DO $$
BEGIN
    RAISE NOTICE 'Initialised: schemas bronze/silver/gold, PostGIS %',
        (SELECT extversion FROM pg_extension WHERE extname = 'postgis');
END $$;
