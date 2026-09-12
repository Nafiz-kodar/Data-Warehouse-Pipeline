/*
===============================================================================
DDL — Gold Layer (business-ready star schema)
===============================================================================
Purpose:
    Exposes the dimensional model as views over Silver. Surrogate keys are
    generated with ROW_NUMBER(), matching the reference project (decision A5).

    Gold is where the two source systems are finally integrated, which is why
    these three defects are resolved here rather than in Silver:

      D3  price disagreement  -> detailed wins; summary only where detail is absent
      D5  36 summary-only listings -> LEFT JOIN from summary keeps all 4,414
      D6  493 orphan review FKs    -> resolved, because D5 restored their listings

    Shape: 2 facts, 5 dimensions, 1 bridge.

Note on dim_date:
    Uses an integer YYYYMMDD "smart key" rather than ROW_NUMBER, which is the
    conventional Kimball treatment: date keys stay stable and human-readable.
    Key -1 is the special Unknown member for the 36 listings whose scrape date
    the summary export does not record.

WARNING: Running this script DROPS and recreates every gold view.
===============================================================================
*/

DROP VIEW IF EXISTS gold.fact_review             CASCADE;
DROP VIEW IF EXISTS gold.fact_listing_snapshot   CASCADE;
DROP VIEW IF EXISTS gold.bridge_listing_amenity  CASCADE;
DROP VIEW IF EXISTS gold.dim_amenity             CASCADE;
DROP VIEW IF EXISTS gold.dim_neighbourhood       CASCADE;
DROP VIEW IF EXISTS gold.dim_host                CASCADE;
DROP VIEW IF EXISTS gold.dim_listing             CASCADE;
DROP VIEW IF EXISTS gold.dim_date                CASCADE;

-- ============================================================================
-- gold.dim_date
-- ============================================================================
CREATE VIEW gold.dim_date AS
SELECT
    -1                                  AS date_key,
    NULL::date                          AS full_date,
    NULL::int                           AS year,
    NULL::int                           AS quarter,
    NULL::int                           AS month,
    'Unknown'::text                     AS month_name,
    NULL::int                           AS day_of_month,
    'Unknown'::text                     AS day_name,
    NULL::boolean                       AS is_weekend,
    TRUE                                AS is_unknown_member
UNION ALL
SELECT
    to_char(d, 'YYYYMMDD')::int,
    d::date,
    EXTRACT(YEAR    FROM d)::int,
    EXTRACT(QUARTER FROM d)::int,
    EXTRACT(MONTH   FROM d)::int,
    to_char(d, 'Month'),
    EXTRACT(DAY     FROM d)::int,
    to_char(d, 'Day'),
    EXTRACT(ISODOW  FROM d) >= 6,
    FALSE
FROM generate_series(DATE '2009-03-01', DATE '2026-12-31', INTERVAL '1 day') AS d;

COMMENT ON VIEW gold.dim_date IS
    'Daily calendar spanning the review history, plus key -1 for unknown dates.';

-- ============================================================================
-- gold.dim_listing   — D3 / D5 resolved here
-- LEFT JOIN from summary: summary is the row superset (4,414), detail the
-- column superset (4,378). Attributes prefer detail; summary fills the 36.
-- ============================================================================
CREATE VIEW gold.dim_listing AS
SELECT
    ROW_NUMBER() OVER (ORDER BY s.listing_id)                AS listing_key,
    s.listing_id,
    COALESCE(d.listing_name, s.listing_name)                 AS listing_name,
    COALESCE(d.neighbourhood, s.neighbourhood)               AS neighbourhood,
    COALESCE(d.room_type, s.room_type)                       AS room_type,
    d.property_type,
    d.accommodates,
    d.bedrooms,
    d.beds,
    d.bathrooms,
    d.bathrooms_is_derived,
    COALESCE(d.latitude,  s.latitude)                        AS latitude,
    COALESCE(d.longitude, s.longitude)                       AS longitude,
    COALESCE(d.license, s.license)                           AS license,
    (COALESCE(d.license, s.license) IS NOT NULL)             AS has_license,
    d.first_review,
    COALESCE(d.last_review, s.last_review)                   AS last_review,
    d.has_availability,
    d.has_unbounded_max_nights,
    d.is_minimum_nights_outlier,
    d.listing_url,
    -- provenance -------------------------------------------------------------
    (d.listing_id IS NOT NULL)                               AS is_detail_sourced,
    COALESCE(d.listing_source, 'summary only')               AS listing_source,
    COALESCE(d.listing_source = 'city scrape', FALSE)        AS is_freshly_scraped
FROM silver.summary_listings s
LEFT JOIN silver.detail_listings d ON d.listing_id = s.listing_id;

COMMENT ON VIEW gold.dim_listing IS
    'One row per listing (4,414). Integrates both sources; is_freshly_scraped '
    'is FALSE for carried-forward listings whose measures may be stale.';

-- ============================================================================
-- gold.dim_host
-- Hosts have zero attribute conflicts (verified), so DISTINCT ON is safe.
-- Hosts known only from the summary export get NULL detail attributes.
-- ============================================================================
CREATE VIEW gold.dim_host AS
WITH detail_hosts AS (
    SELECT DISTINCT ON (host_id)
        host_id, host_name, host_profile_id, host_is_superhost,
        host_location, host_years_as_host, host_months_as_host,
        host_listings_count, host_has_profile_pic, host_identity_verified,
        TRUE AS is_detail_sourced
    FROM silver.detail_listings
    WHERE host_id IS NOT NULL
    ORDER BY host_id
), summary_only_hosts AS (
    SELECT DISTINCT ON (s.host_id)
        s.host_id, s.host_name, s.host_profile_id,
        NULL::boolean, NULL::text, NULL::int, NULL::int,
        NULL::int, NULL::boolean, NULL::boolean,
        FALSE
    FROM silver.summary_listings s
    WHERE s.host_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM detail_hosts h WHERE h.host_id = s.host_id)
    ORDER BY s.host_id
), all_hosts AS (
    SELECT * FROM detail_hosts
    UNION ALL
    SELECT * FROM summary_only_hosts
)
SELECT
    ROW_NUMBER() OVER (ORDER BY host_id)                     AS host_key,
    host_id,
    host_name,
    host_profile_id,
    host_is_superhost,
    host_location,
    host_years_as_host,
    host_months_as_host,
    host_listings_count,
    host_has_profile_pic,
    host_identity_verified,
    is_detail_sourced,
    (host_listings_count > 1)                                AS is_multi_listing_host
FROM all_hosts;

COMMENT ON VIEW gold.dim_host IS 'One row per host. Source data has no host attribute conflicts.';

-- ============================================================================
-- gold.dim_neighbourhood   — includes the repaired PostGIS boundary (D15)
-- ============================================================================
CREATE VIEW gold.dim_neighbourhood AS
SELECT
    ROW_NUMBER() OVER (ORDER BY n.neighbourhood)             AS neighbourhood_key,
    n.neighbourhood,
    n.geom,
    n.geom_was_repaired,
    n.area_sqkm,
    n.centroid_latitude,
    n.centroid_longitude
FROM silver.neighbourhoods n;

COMMENT ON VIEW gold.dim_neighbourhood IS
    '26 Boston neighbourhoods with validated MultiPolygon boundaries. '
    'Harbor Islands legitimately has no listings.';

-- ============================================================================
-- gold.dim_amenity   — D7
-- ============================================================================
CREATE VIEW gold.dim_amenity AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.amenity)                   AS amenity_key,
    a.amenity,
    a.listing_count
FROM (
    SELECT amenity, count(*) AS listing_count
    FROM silver.detail_listing_amenity
    GROUP BY amenity
) a;

COMMENT ON VIEW gold.dim_amenity IS '1,434 distinct amenities with their listing frequency.';

-- ============================================================================
-- gold.bridge_listing_amenity   — resolves the many-to-many
-- ============================================================================
CREATE VIEW gold.bridge_listing_amenity AS
SELECT
    dl.listing_key,
    da.amenity_key
FROM silver.detail_listing_amenity la
JOIN gold.dim_listing dl ON dl.listing_id = la.listing_id
JOIN gold.dim_amenity  da ON da.amenity    = la.amenity;

COMMENT ON VIEW gold.bridge_listing_amenity IS
    'One row per listing-amenity pair (155,233). Grain is enforced in Silver.';

-- ============================================================================
-- gold.fact_listing_snapshot
-- Grain: one row per listing per scrape_date (decision A5).
-- The 36 listings with no recorded scrape date use date_key -1.
-- ============================================================================
CREATE VIEW gold.fact_listing_snapshot AS
SELECT
    dl.listing_key,
    COALESCE(to_char(d.scrape_date, 'YYYYMMDD')::int, -1)    AS scrape_date_key,
    dh.host_key,
    dn.neighbourhood_key,
    -- measures ---------------------------------------------------------------
    COALESCE(d.price, s.price)                               AS price_amount,   -- D3
    d.price_quote_total_price,
    d.price_quote_price_per_night,
    COALESCE(d.minimum_nights, s.minimum_nights)             AS minimum_nights,
    d.maximum_nights,                                                           -- D14
    d.availability_30,
    d.availability_60,
    d.availability_90,
    COALESCE(d.availability_365, s.availability_365)         AS availability_365,
    d.availability_eoy,
    d.estimated_occupancy_l365d,
    d.estimated_revenue_l365d,
    COALESCE(d.number_of_reviews, s.number_of_reviews)       AS number_of_reviews,
    COALESCE(d.number_of_reviews_ltm, s.number_of_reviews_ltm) AS number_of_reviews_ltm,
    d.number_of_reviews_l30d,
    COALESCE(d.reviews_per_month, s.reviews_per_month)       AS reviews_per_month,
    d.review_scores_rating,                                                     -- D11 NULL is meaningful
    d.review_scores_accuracy,
    d.review_scores_cleanliness,
    d.review_scores_checkin,
    d.review_scores_communication,
    d.review_scores_location,
    d.review_scores_value,
    -- degenerate / provenance ------------------------------------------------
    dl.is_detail_sourced,
    dl.is_freshly_scraped
FROM silver.summary_listings s
LEFT JOIN silver.detail_listings   d  ON d.listing_id = s.listing_id
JOIN      gold.dim_listing         dl ON dl.listing_id = s.listing_id
LEFT JOIN gold.dim_host            dh ON dh.host_id = COALESCE(d.host_id, s.host_id)
LEFT JOIN gold.dim_neighbourhood   dn ON dn.neighbourhood = COALESCE(d.neighbourhood, s.neighbourhood);

COMMENT ON VIEW gold.fact_listing_snapshot IS
    'Periodic snapshot, grain = listing x scrape_date (4,414 rows today). '
    'Filter on is_freshly_scraped to exclude carried-forward listings.';

-- ============================================================================
-- gold.fact_review   — D6 resolved: every listing_id now finds a dim_listing row
-- Grain: one row per review.
-- ============================================================================
CREATE VIEW gold.fact_review AS
SELECT
    r.review_id,
    dl.listing_key,
    to_char(r.review_date, 'YYYYMMDD')::int                  AS review_date_key,
    dh.host_key,
    dn.neighbourhood_key,
    r.reviewer_id,
    r.reviewer_name,
    r.review_date,
    length(r.comments)                                       AS comment_length,
    r.comments
FROM silver.detail_reviews r
JOIN      gold.dim_listing       dl ON dl.listing_id = r.listing_id
LEFT JOIN silver.detail_listings  sd ON sd.listing_id = r.listing_id
LEFT JOIN silver.summary_listings ss ON ss.listing_id = r.listing_id
LEFT JOIN gold.dim_host          dh ON dh.host_id = COALESCE(sd.host_id, ss.host_id)
LEFT JOIN gold.dim_neighbourhood dn ON dn.neighbourhood = dl.neighbourhood;

COMMENT ON VIEW gold.fact_review IS
    'One row per review (252,910). INNER JOIN to dim_listing is deliberate: it '
    'must not drop rows, which proves D6 orphan foreign keys are resolved.';
