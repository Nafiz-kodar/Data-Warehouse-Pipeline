/*
===============================================================================
Quality Checks — Gold Layer
===============================================================================
Purpose:
    Asserts the dimensional model is structurally sound: surrogate keys unique,
    every fact foreign key resolves, declared grains hold, and the cross-source
    integration (D3/D5/D6) actually delivered what the charter promised.

Usage:
    docker compose exec -T postgres psql -U dwh -d datawarehouse \
        -f - < tests/quality_checks_gold.sql

Expected: every row reads PASS.
===============================================================================
*/

WITH checks AS (

-- ---------------------------------------------------------------- dimension counts
SELECT 'G01' id, 'dim_listing row count (integrated union)' descr, count(*) actual, 4414::bigint expected FROM gold.dim_listing
UNION ALL
SELECT 'G02', 'dim_host row count',                              count(*), 1406   FROM gold.dim_host
UNION ALL
SELECT 'G03', 'dim_neighbourhood row count',                     count(*), 26     FROM gold.dim_neighbourhood
UNION ALL
SELECT 'G04', 'dim_amenity row count',                           count(*), 1434   FROM gold.dim_amenity
UNION ALL
SELECT 'G05', 'bridge_listing_amenity row count',                count(*), 155233 FROM gold.bridge_listing_amenity
UNION ALL
SELECT 'G06', 'fact_listing_snapshot row count',                 count(*), 4414   FROM gold.fact_listing_snapshot
UNION ALL
SELECT 'G07', 'fact_review row count',                           count(*), 252910 FROM gold.fact_review

-- ---------------------------------------------------------------- surrogate keys
UNION ALL
SELECT 'G08', 'surrogate key unique: dim_listing',
       count(*) - count(DISTINCT listing_key), 0 FROM gold.dim_listing
UNION ALL
SELECT 'G09', 'surrogate key unique: dim_host',
       count(*) - count(DISTINCT host_key), 0 FROM gold.dim_host
UNION ALL
SELECT 'G10', 'surrogate key unique: dim_neighbourhood',
       count(*) - count(DISTINCT neighbourhood_key), 0 FROM gold.dim_neighbourhood
UNION ALL
SELECT 'G11', 'surrogate key unique: dim_amenity',
       count(*) - count(DISTINCT amenity_key), 0 FROM gold.dim_amenity
UNION ALL
SELECT 'G12', 'natural key unique: dim_listing.listing_id',
       count(*) - count(DISTINCT listing_id), 0 FROM gold.dim_listing
UNION ALL
SELECT 'G13', 'natural key unique: dim_host.host_id',
       count(*) - count(DISTINCT host_id), 0 FROM gold.dim_host

-- ---------------------------------------------------------------- declared grains
UNION ALL
SELECT 'G14', 'grain: fact_listing_snapshot is listing x scrape_date',
       count(*) - count(DISTINCT (listing_key, scrape_date_key)), 0
       FROM gold.fact_listing_snapshot
UNION ALL
SELECT 'G15', 'grain: fact_review is one row per review',
       count(*) - count(DISTINCT review_id), 0 FROM gold.fact_review
UNION ALL
SELECT 'G16', 'grain: bridge has no duplicate pairs',
       count(*) - count(DISTINCT (listing_key, amenity_key)), 0
       FROM gold.bridge_listing_amenity

-- ---------------------------------------------------------------- referential integrity
UNION ALL
SELECT 'G17', 'D6: fact_review has no orphan listing_key',
       count(*) FILTER (WHERE listing_key IS NULL), 0 FROM gold.fact_review
UNION ALL
SELECT 'G18', 'fact_review.listing_key all resolve to dim_listing',
       count(*), 0 FROM gold.fact_review f
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_listing d WHERE d.listing_key = f.listing_key)
UNION ALL
SELECT 'G19', 'fact_snapshot.listing_key all resolve to dim_listing',
       count(*), 0 FROM gold.fact_listing_snapshot f
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_listing d WHERE d.listing_key = f.listing_key)
UNION ALL
SELECT 'G20', 'fact_snapshot.scrape_date_key all resolve to dim_date',
       count(*), 0 FROM gold.fact_listing_snapshot f
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date d WHERE d.date_key = f.scrape_date_key)
UNION ALL
SELECT 'G21', 'fact_review.review_date_key all resolve to dim_date',
       count(*), 0 FROM gold.fact_review f
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date d WHERE d.date_key = f.review_date_key)
UNION ALL
SELECT 'G22', 'bridge keys all resolve to their dimensions',
       count(*), 0 FROM gold.bridge_listing_amenity b
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_listing l WHERE l.listing_key = b.listing_key)
          OR NOT EXISTS (SELECT 1 FROM gold.dim_amenity  a WHERE a.amenity_key = b.amenity_key)

-- ---------------------------------------------------------------- integration (D3/D5)
UNION ALL
SELECT 'G23', 'D5: 36 summary-only listings survived integration',
       count(*) FILTER (WHERE NOT is_detail_sourced), 36 FROM gold.dim_listing
UNION ALL
SELECT 'G24', 'D5: unknown-date member used for exactly those 36',
       count(*) FILTER (WHERE scrape_date_key = -1), 36 FROM gold.fact_listing_snapshot
UNION ALL
SELECT 'G25', 'D3: price prefers the detailed source where present',
       count(*), 0 FROM gold.fact_listing_snapshot f
       JOIN gold.dim_listing dl USING (listing_key)
       JOIN silver.detail_listings d ON d.listing_id = dl.listing_id
       WHERE d.price IS NOT NULL AND f.price_amount <> d.price
UNION ALL
SELECT 'G26', 'D1: provenance flag agrees with listing_source',
       count(*), 0 FROM gold.dim_listing
       WHERE is_freshly_scraped <> (listing_source = 'city scrape')

-- ---------------------------------------------------------------- dim_date
UNION ALL
SELECT 'G27', 'dim_date contains the Unknown member',
       count(*) FILTER (WHERE date_key = -1 AND is_unknown_member), 1 FROM gold.dim_date
UNION ALL
SELECT 'G28', 'dim_date has exactly one row per real date',
       count(*) - count(DISTINCT date_key), 0 FROM gold.dim_date

-- ---------------------------------------------------------------- spatial (O4)
UNION ALL
SELECT 'G29', 'O4: every listing falls inside its neighbourhood polygon',
       count(*) FILTER (WHERE NOT ST_Contains(dn.geom,
                 ST_SetSRID(ST_MakePoint(dl.longitude, dl.latitude), 4326))), 0
       FROM gold.dim_listing dl
       JOIN gold.dim_neighbourhood dn USING (neighbourhood)
       WHERE dl.latitude IS NOT NULL AND dl.longitude IS NOT NULL

-- ---------------------------------------------------------------- measure sanity
UNION ALL
SELECT 'G30', 'no negative measures in fact_listing_snapshot',
       count(*) FILTER (WHERE price_amount < 0 OR availability_365 < 0
                           OR estimated_revenue_l365d < 0), 0
       FROM gold.fact_listing_snapshot
UNION ALL
SELECT 'G31', 'availability_365 within 0..365',
       count(*) FILTER (WHERE availability_365 NOT BETWEEN 0 AND 365), 0
       FROM gold.fact_listing_snapshot
UNION ALL
SELECT 'G32', 'review scores within 0..5',
       count(*) FILTER (WHERE review_scores_rating NOT BETWEEN 0 AND 5), 0
       FROM gold.fact_listing_snapshot
)
SELECT
    id                                                        AS check_id,
    descr                                                     AS description,
    actual,
    expected,
    CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END   AS result
FROM checks
ORDER BY id;
