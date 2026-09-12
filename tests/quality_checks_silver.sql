/*
===============================================================================
Quality Checks — Silver Layer
===============================================================================
Purpose:
    Asserts that every defect the cleaning specification registered was actually
    resolved, and that no rows were lost or invented between Bronze and Silver.

    Returns one row per check with PASS / FAIL, so the suite is readable in psql
    and loads directly into a DataFrame from the notebook.

Usage:
    docker compose exec -T postgres psql -U dwh -d datawarehouse \
        -f - < tests/quality_checks_silver.sql

Expected: every row reads PASS.
===============================================================================
*/

WITH checks AS (

-- ---------------------------------------------------------------- row counts
SELECT 'S01' id, 'row count: summary_listings'          descr, count(*) actual, 4414::bigint expected FROM silver.summary_listings
UNION ALL
SELECT 'S02', 'row count: detail_listings',                   count(*), 4378      FROM silver.detail_listings
UNION ALL
SELECT 'S03', 'row count: detail_reviews',                    count(*), 252910    FROM silver.detail_reviews
UNION ALL
SELECT 'S04', 'row count: neighbourhoods',                    count(*), 26        FROM silver.neighbourhoods
UNION ALL
SELECT 'S05', 'row count: detail_listing_amenity',            count(*), 155233    FROM silver.detail_listing_amenity

-- ---------------------------------------------------------------- key integrity
UNION ALL
SELECT 'S06', 'PK unique: summary_listings.listing_id',
       count(*) - count(DISTINCT listing_id), 0 FROM silver.summary_listings
UNION ALL
SELECT 'S07', 'PK unique: detail_listings.listing_id',
       count(*) - count(DISTINCT listing_id), 0 FROM silver.detail_listings
UNION ALL
SELECT 'S08', 'PK unique: detail_reviews.review_id',
       count(*) - count(DISTINCT review_id), 0 FROM silver.detail_reviews
UNION ALL
SELECT 'S09', 'no NULL business keys in detail_reviews',
       count(*) FILTER (WHERE review_id IS NULL OR listing_id IS NULL), 0 FROM silver.detail_reviews

-- ---------------------------------------------------------------- D2 price
UNION ALL
SELECT 'S10', 'D2: price cast to numeric, count preserved',
       count(*) FILTER (WHERE price IS NOT NULL), 3693 FROM silver.detail_listings
UNION ALL
SELECT 'S11', 'D2: no negative prices',
       count(*) FILTER (WHERE price < 0), 0 FROM silver.detail_listings

-- ---------------------------------------------------------------- D4 no imputation
UNION ALL
SELECT 'S12', 'D4: missing prices left NULL, not zero-filled',
       count(*) FILTER (WHERE price IS NULL), 685 FROM silver.detail_listings

-- ---------------------------------------------------------------- D7 amenities
UNION ALL
SELECT 'S13', 'D7: distinct amenities extracted',
       count(DISTINCT amenity), 1434 FROM silver.detail_listing_amenity
UNION ALL
SELECT 'S14', 'D7: no blank amenity strings',
       count(*) FILTER (WHERE TRIM(amenity) = ''), 0 FROM silver.detail_listing_amenity

-- ---------------------------------------------------------------- D8 bathrooms
UNION ALL
SELECT 'S15', 'D8: no NULL bathrooms where bathrooms_text exists',
       count(*) FILTER (WHERE bathrooms IS NULL AND bathrooms_text IS NOT NULL), 0
       FROM silver.detail_listings
UNION ALL
SELECT 'S16', 'D8: bathrooms recovered from text',
       count(*) FILTER (WHERE bathrooms_is_derived), 1030 FROM silver.detail_listings

-- ---------------------------------------------------------------- D9/D10 dropped cols
UNION ALL
SELECT 'S17', 'D9: all-NULL source columns not carried into Silver',
       count(*), 0 FROM information_schema.columns
       WHERE table_schema = 'silver' AND table_name = 'detail_listings'
         AND column_name IN ('host_since','instant_bookable','host_response_time',
             'host_response_rate','host_acceptance_rate','host_verifications',
             'host_thumbnail_url','host_neighbourhood','host_total_listings_count',
             'calendar_updated','neighborhood_overview','neighbourhood_group_cleansed')
UNION ALL
SELECT 'S18', 'D10: neighbourhood_group dropped everywhere',
       count(*), 0 FROM information_schema.columns
       WHERE table_schema = 'silver' AND column_name LIKE 'neighbourhood_group%'

-- ---------------------------------------------------------------- D11 nulls preserved
UNION ALL
SELECT 'S19', 'D11: review scores NULL for unreviewed listings',
       count(*) FILTER (WHERE review_scores_rating IS NULL), 901 FROM silver.detail_listings
UNION ALL
SELECT 'S20', 'D11: no zero-filled ratings',
       count(*) FILTER (WHERE review_scores_rating = 0), 0 FROM silver.detail_listings

-- ---------------------------------------------------------------- D12 outlier
UNION ALL
SELECT 'S21', 'D12: minimum_nights outlier flagged, value retained',
       count(*) FILTER (WHERE is_minimum_nights_outlier AND minimum_nights = 400), 1
       FROM silver.detail_listings

-- ---------------------------------------------------------------- D13 booleans
UNION ALL
SELECT 'S22', 'D13: t/f columns are native boolean',
       count(*), 4 FROM information_schema.columns
       WHERE table_schema = 'silver' AND table_name = 'detail_listings'
         AND data_type = 'boolean'
         AND column_name IN ('host_is_superhost','host_has_profile_pic',
                             'host_identity_verified','has_availability')

-- ---------------------------------------------------------------- D14 sentinel
UNION ALL
SELECT 'S23', 'D14: INT32_MAX sentinel removed from maximum_nights',
       count(*) FILTER (WHERE maximum_nights = 2147483647), 0 FROM silver.detail_listings
UNION ALL
SELECT 'S24', 'D14: sentinel removed from all max-nights columns',
       count(*) FILTER (WHERE minimum_maximum_nights = 2147483647
                           OR maximum_maximum_nights = 2147483647
                           OR maximum_nights_avg_ntm = 2147483647), 0
       FROM silver.detail_listings
UNION ALL
SELECT 'S25', 'D14: unbounded stays flagged instead',
       count(*) FILTER (WHERE has_unbounded_max_nights), 9 FROM silver.detail_listings

-- ---------------------------------------------------------------- D15 geometry
UNION ALL
SELECT 'S26', 'D15: no invalid geometries remain',
       count(*) FILTER (WHERE NOT ST_IsValid(geom)), 0 FROM silver.neighbourhoods
UNION ALL
SELECT 'S27', 'D15: repaired polygons flagged',
       count(*) FILTER (WHERE geom_was_repaired), 4 FROM silver.neighbourhoods
UNION ALL
SELECT 'S28', 'D15: all geometries are SRID 4326 MultiPolygon',
       count(*) FILTER (WHERE ST_SRID(geom) <> 4326
                           OR GeometryType(geom) <> 'MULTIPOLYGON'), 0
       FROM silver.neighbourhoods

-- ---------------------------------------------------------------- D1 provenance
UNION ALL
SELECT 'S29', 'D1: three distinct scrape dates preserved',
       count(DISTINCT scrape_date), 3 FROM silver.detail_listings
UNION ALL
SELECT 'S30', 'D1: listing_source populated for every row',
       count(*) FILTER (WHERE listing_source IS NULL), 0 FROM silver.detail_listings

-- ---------------------------------------------------------------- referential
UNION ALL
SELECT 'S31', 'every detail neighbourhood exists in the lookup',
       count(*), 0 FROM (
           SELECT DISTINCT neighbourhood FROM silver.detail_listings
           WHERE neighbourhood IS NOT NULL
           EXCEPT SELECT neighbourhood FROM silver.neighbourhoods) x
UNION ALL
SELECT 'S32', 'every amenity row maps to a real listing',
       count(*), 0 FROM silver.detail_listing_amenity a
       WHERE NOT EXISTS (SELECT 1 FROM silver.detail_listings d
                         WHERE d.listing_id = a.listing_id)
UNION ALL
SELECT 'S33', 'review dates fall inside the expected window',
       count(*) FILTER (WHERE review_date < DATE '2009-01-01'
                           OR review_date > DATE '2026-12-31'), 0
       FROM silver.detail_reviews
)
SELECT
    id                                                        AS check_id,
    descr                                                     AS description,
    actual,
    expected,
    CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END   AS result
FROM checks
ORDER BY id;
