/*
===============================================================================
Stored Procedure — Load Silver Layer  (Bronze -> Silver)
===============================================================================
Purpose:
    Truncate-and-reload every Silver table, applying the cleaning rules specified
    in docs/cleaning_spec.md. Each block below names the defect it resolves.

    Resolved here : D1 D2 D4 D7 D8 D9 D10 D11 D12 D13 D14 D15
    Resolved later: D3 D5 D6  (Gold - they require joining the two sources)

Usage:
    CALL silver.load_silver();
===============================================================================
*/
CREATE OR REPLACE PROCEDURE silver.load_silver()
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz;
    v_batch timestamptz := clock_timestamp();
    v_rows  bigint;
BEGIN
    RAISE NOTICE '================================================';
    RAISE NOTICE 'Loading Silver Layer';
    RAISE NOTICE '================================================';

    ---------------------------------------------------------------- summary_listings
    -- D10: neighbourhood_group dropped (100% empty in both sources)
    RAISE NOTICE '>> silver.summary_listings';
    v_start := clock_timestamp();
    TRUNCATE TABLE silver.summary_listings;
    INSERT INTO silver.summary_listings (
        listing_id, listing_name, host_id, host_profile_id, host_name, neighbourhood, latitude, longitude, room_type, price, minimum_nights, number_of_reviews, last_review, reviews_per_month, calculated_host_listings_count, availability_365, number_of_reviews_ltm, license
    )
    SELECT
        NULLIF(id, '')::BIGINT                                                 AS listing_id,
        NULLIF(TRIM(name), '')                                                 AS listing_name,
        NULLIF(host_id, '')::BIGINT                                            AS host_id,
        NULLIF(host_profile_id, '')::BIGINT                                    AS host_profile_id,
        NULLIF(TRIM(host_name), '')                                            AS host_name,
        NULLIF(TRIM(neighbourhood), '')                                        AS neighbourhood,
        NULLIF(latitude, '')::NUMERIC                                          AS latitude,
        NULLIF(longitude, '')::NUMERIC                                         AS longitude,
        NULLIF(TRIM(room_type), '')                                            AS room_type,
        NULLIF(REPLACE(REPLACE(price, '$', ''), ',', ''), '')::NUMERIC         AS price,
        NULLIF(minimum_nights, '')::INT                                        AS minimum_nights,
        NULLIF(number_of_reviews, '')::INT                                     AS number_of_reviews,
        NULLIF(last_review, '')::DATE                                          AS last_review,
        NULLIF(reviews_per_month, '')::NUMERIC                                 AS reviews_per_month,
        NULLIF(calculated_host_listings_count, '')::INT                        AS calculated_host_listings_count,
        NULLIF(availability_365, '')::INT                                      AS availability_365,
        NULLIF(number_of_reviews_ltm, '')::INT                                 AS number_of_reviews_ltm,
        NULLIF(TRIM(license), '')                                              AS license
    FROM bronze.summary_listings;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE '   % rows in %', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- detail_listings
    -- D1  last_scraped -> scrape_date, source -> listing_source (provenance)
    -- D2  price text -> numeric        D8  bathrooms recovered from bathrooms_text
    -- D9  13 all-NULL columns not carried
    -- D12 minimum_nights outlier flagged, value retained
    -- D13 't'/'f' -> boolean
    RAISE NOTICE '>> silver.detail_listings';
    v_start := clock_timestamp();
    TRUNCATE TABLE silver.detail_listings;
    INSERT INTO silver.detail_listings (
        listing_id, listing_url, scrape_id, scrape_date, listing_source, listing_name, description, picture_url, host_id, host_url, host_profile_id, host_profile_url, host_name, host_years_as_user, host_months_as_user, host_years_as_host, host_months_as_host, host_location, host_about, host_is_superhost, host_picture_url, host_listings_count, host_has_profile_pic, host_identity_verified, neighbourhood, latitude, longitude, property_type, room_type, accommodates, bathrooms, bathrooms_is_derived, bathrooms_text, bedrooms, beds, amenities, price, price_quote_checkin_date, price_quote_checkout_date, price_quote_total_price, price_quote_price_per_night, minimum_nights, maximum_nights, has_unbounded_max_nights, is_minimum_nights_outlier, minimum_minimum_nights, maximum_minimum_nights, minimum_maximum_nights, maximum_maximum_nights, minimum_nights_avg_ntm, maximum_nights_avg_ntm, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, calendar_last_scraped, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly, estimated_occupancy_l365d, estimated_revenue_l365d, first_review, last_review, review_scores_rating, review_scores_accuracy, review_scores_cleanliness, review_scores_checkin, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month, license, calculated_host_listings_count, calculated_host_listings_count_entire_homes, calculated_host_listings_count_private_rooms, calculated_host_listings_count_shared_rooms
    )
    SELECT
        NULLIF(id, '')::BIGINT                                                 AS listing_id,
        NULLIF(TRIM(listing_url), '')                                          AS listing_url,
        NULLIF(scrape_id, '')::BIGINT                                          AS scrape_id,
        NULLIF(last_scraped, '')::DATE                                         AS scrape_date,
        NULLIF(TRIM(source), '')                                               AS listing_source,
        NULLIF(TRIM(name), '')                                                 AS listing_name,
        NULLIF(TRIM(description), '')                                          AS description,
        NULLIF(TRIM(picture_url), '')                                          AS picture_url,
        NULLIF(host_id, '')::BIGINT                                            AS host_id,
        NULLIF(TRIM(host_url), '')                                             AS host_url,
        NULLIF(host_profile_id, '')::BIGINT                                    AS host_profile_id,
        NULLIF(TRIM(host_profile_url), '')                                     AS host_profile_url,
        NULLIF(TRIM(host_name), '')                                            AS host_name,
        NULLIF(hosts_time_as_user_years, '')::INT                              AS host_years_as_user,
        NULLIF(hosts_time_as_user_months, '')::INT                             AS host_months_as_user,
        NULLIF(hosts_time_as_host_years, '')::INT                              AS host_years_as_host,
        NULLIF(hosts_time_as_host_months, '')::INT                             AS host_months_as_host,
        NULLIF(TRIM(host_location), '')                                        AS host_location,
        NULLIF(TRIM(host_about), '')                                           AS host_about,
        (NULLIF(host_is_superhost, '') = 't')                                  AS host_is_superhost,
        NULLIF(TRIM(host_picture_url), '')                                     AS host_picture_url,
        NULLIF(host_listings_count, '')::INT                                   AS host_listings_count,
        (NULLIF(host_has_profile_pic, '') = 't')                               AS host_has_profile_pic,
        (NULLIF(host_identity_verified, '') = 't')                             AS host_identity_verified,
        NULLIF(TRIM(neighbourhood_cleansed), '')                               AS neighbourhood,
        NULLIF(latitude, '')::NUMERIC                                          AS latitude,
        NULLIF(longitude, '')::NUMERIC                                         AS longitude,
        NULLIF(TRIM(property_type), '')                                        AS property_type,
        NULLIF(TRIM(room_type), '')                                            AS room_type,
        NULLIF(accommodates, '')::INT                                          AS accommodates,
        COALESCE(
            NULLIF(bathrooms, '')::NUMERIC,
            CASE WHEN bathrooms_text ILIKE '%half-bath%' THEN 0.5
                 ELSE NULLIF((regexp_match(bathrooms_text, '([0-9]+\.?[0-9]*)'))[1], '')::NUMERIC
            END
        ) AS bathrooms,
        (NULLIF(bathrooms, '') IS NULL AND NULLIF(bathrooms_text, '') IS NOT NULL) AS bathrooms_is_derived,
        NULLIF(TRIM(bathrooms_text), '')                                       AS bathrooms_text,
        NULLIF(bedrooms, '')::INT                                              AS bedrooms,
        NULLIF(beds, '')::INT                                                  AS beds,
        NULLIF(amenities, '')::JSONB                                           AS amenities,
        NULLIF(REPLACE(REPLACE(price, '$', ''), ',', ''), '')::NUMERIC         AS price,
        NULLIF(price_quote_checkin_date, '')::DATE                             AS price_quote_checkin_date,
        NULLIF(price_quote_checkout_date, '')::DATE                            AS price_quote_checkout_date,
        NULLIF(REPLACE(REPLACE(price_quote_total_price, '$', ''), ',', ''), '')::NUMERIC AS price_quote_total_price,
        NULLIF(REPLACE(REPLACE(price_quote_price_per_night, '$', ''), ',', ''), '')::NUMERIC AS price_quote_price_per_night,
        NULLIF(minimum_nights, '')::INT                                        AS minimum_nights,
        NULLIF(NULLIF(maximum_nights, '')::INT, 2147483647)                    AS maximum_nights,
        (NULLIF(maximum_nights, '')::INT = 2147483647)                         AS has_unbounded_max_nights,
        (NULLIF(minimum_nights, '')::INT > 365)                                AS is_minimum_nights_outlier,
        NULLIF(minimum_minimum_nights, '')::INT                                AS minimum_minimum_nights,
        NULLIF(maximum_minimum_nights, '')::INT                                AS maximum_minimum_nights,
        NULLIF(NULLIF(minimum_maximum_nights, '')::INT, 2147483647)            AS minimum_maximum_nights,
        NULLIF(NULLIF(maximum_maximum_nights, '')::INT, 2147483647)            AS maximum_maximum_nights,
        NULLIF(minimum_nights_avg_ntm, '')::NUMERIC                            AS minimum_nights_avg_ntm,
        NULLIF(NULLIF(maximum_nights_avg_ntm, '')::NUMERIC, 2147483647)        AS maximum_nights_avg_ntm,
        (NULLIF(has_availability, '') = 't')                                   AS has_availability,
        NULLIF(availability_30, '')::INT                                       AS availability_30,
        NULLIF(availability_60, '')::INT                                       AS availability_60,
        NULLIF(availability_90, '')::INT                                       AS availability_90,
        NULLIF(availability_365, '')::INT                                      AS availability_365,
        NULLIF(availability_eoy, '')::INT                                      AS availability_eoy,
        NULLIF(calendar_last_scraped, '')::DATE                                AS calendar_last_scraped,
        NULLIF(number_of_reviews, '')::INT                                     AS number_of_reviews,
        NULLIF(number_of_reviews_ltm, '')::INT                                 AS number_of_reviews_ltm,
        NULLIF(number_of_reviews_l30d, '')::INT                                AS number_of_reviews_l30d,
        NULLIF(number_of_reviews_ly, '')::INT                                  AS number_of_reviews_ly,
        NULLIF(estimated_occupancy_l365d, '')::INT                             AS estimated_occupancy_l365d,
        NULLIF(REPLACE(REPLACE(estimated_revenue_l365d, '$', ''), ',', ''), '')::NUMERIC AS estimated_revenue_l365d,
        NULLIF(first_review, '')::DATE                                         AS first_review,
        NULLIF(last_review, '')::DATE                                          AS last_review,
        NULLIF(review_scores_rating, '')::NUMERIC                              AS review_scores_rating,
        NULLIF(review_scores_accuracy, '')::NUMERIC                            AS review_scores_accuracy,
        NULLIF(review_scores_cleanliness, '')::NUMERIC                         AS review_scores_cleanliness,
        NULLIF(review_scores_checkin, '')::NUMERIC                             AS review_scores_checkin,
        NULLIF(review_scores_communication, '')::NUMERIC                       AS review_scores_communication,
        NULLIF(review_scores_location, '')::NUMERIC                            AS review_scores_location,
        NULLIF(review_scores_value, '')::NUMERIC                               AS review_scores_value,
        NULLIF(reviews_per_month, '')::NUMERIC                                 AS reviews_per_month,
        NULLIF(TRIM(license), '')                                              AS license,
        NULLIF(calculated_host_listings_count, '')::INT                        AS calculated_host_listings_count,
        NULLIF(calculated_host_listings_count_entire_homes, '')::INT           AS calculated_host_listings_count_entire_homes,
        NULLIF(calculated_host_listings_count_private_rooms, '')::INT          AS calculated_host_listings_count_private_rooms,
        NULLIF(calculated_host_listings_count_shared_rooms, '')::INT           AS calculated_host_listings_count_shared_rooms
    FROM bronze.detail_listings;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE '   % rows in %', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- detail_reviews
    RAISE NOTICE '>> silver.detail_reviews';
    v_start := clock_timestamp();
    TRUNCATE TABLE silver.detail_reviews;
    INSERT INTO silver.detail_reviews (
        review_id, listing_id, review_date, reviewer_id, reviewer_name, comments
    )
    SELECT
        NULLIF(id, '')::BIGINT                                                 AS review_id,
        NULLIF(listing_id, '')::BIGINT                                         AS listing_id,
        NULLIF(date, '')::DATE                                                 AS review_date,
        NULLIF(reviewer_id, '')::BIGINT                                        AS reviewer_id,
        NULLIF(TRIM(reviewer_name), '')                                        AS reviewer_name,
        NULLIF(TRIM(comments), '')                                             AS comments
    FROM bronze.detail_reviews;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE '   % rows in %', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- neighbourhoods
    -- Joins the name lookup to its GeoJSON boundary (decision: raw jsonb -> PostGIS).
    RAISE NOTICE '>> silver.neighbourhoods';
    v_start := clock_timestamp();
    TRUNCATE TABLE silver.neighbourhoods;
    -- D15: 4 of the 26 source polygons are self-intersecting. Left unrepaired they
    -- make ST_Contains unreliable, so ST_MakeValid fixes them and the repair is
    -- recorded rather than hidden. CollectionExtract(...,3) keeps only polygons,
    -- since MakeValid can emit a GeometryCollection.
    INSERT INTO silver.neighbourhoods (
        neighbourhood, geom, geom_was_repaired, area_sqkm,
        centroid_latitude, centroid_longitude
    )
    WITH features AS (
        SELECT
            f -> 'properties' ->> 'neighbourhood'                    AS neighbourhood,
            ST_SetSRID(ST_GeomFromGeoJSON(f -> 'geometry'), 4326)    AS geom_raw
        FROM bronze.geo_neighbourhoods_raw,
             jsonb_array_elements(doc -> 'features') AS f
    ), repaired AS (
        SELECT
            neighbourhood,
            NOT ST_IsValid(geom_raw)                                              AS was_repaired,
            ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_raw), 3))             AS geom
        FROM features
    )
    SELECT
        r.neighbourhood,
        r.geom,
        r.was_repaired,
        ROUND((ST_Area(r.geom::geography) / 1000000.0)::numeric, 4),
        ROUND(ST_Y(ST_Centroid(r.geom))::numeric, 6),
        ROUND(ST_X(ST_Centroid(r.geom))::numeric, 6)
    FROM repaired r;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE '   % rows in %', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- amenities (D7)
    -- DISTINCT because a listing may repeat an amenity; the bridge grain is
    -- one row per listing-amenity pair.
    RAISE NOTICE '>> silver.detail_listing_amenity';
    v_start := clock_timestamp();
    TRUNCATE TABLE silver.detail_listing_amenity;
    INSERT INTO silver.detail_listing_amenity (listing_id, amenity)
    SELECT DISTINCT
        NULLIF(b.id, '')::BIGINT,
        TRIM(a.value)
    FROM bronze.detail_listings b,
         jsonb_array_elements_text(NULLIF(b.amenities, '')::jsonb) AS a(value)
    WHERE b.amenities IS NOT NULL
      AND TRIM(a.value) <> '';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE '   % rows in %', v_rows, clock_timestamp() - v_start;

    RAISE NOTICE '================================================';
    RAISE NOTICE 'Silver load complete in %', clock_timestamp() - v_batch;
    RAISE NOTICE '================================================';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '!! SILVER LOAD FAILED: % (SQLSTATE %)', SQLERRM, SQLSTATE;
    RAISE;
END;
$$;
