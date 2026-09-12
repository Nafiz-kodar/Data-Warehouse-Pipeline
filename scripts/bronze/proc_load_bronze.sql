/*
===============================================================================
Stored Procedure — Load Bronze Layer  (Source -> Bronze)
===============================================================================
Purpose:
    Truncate-and-reload every Bronze table from the CSV drop mounted read-only at
    /datasets inside the container. Server-side COPY is the PostgreSQL analogue of
    the reference project's T-SQL BULK INSERT, which keeps the whole load inside a
    single self-contained stored procedure.

    COPY ... FORMAT csv correctly handles the quoted newlines measured in
    notebooks/01_data_cleaning.ipynb §1.1 — do not substitute FORMAT text.

    reviews_summary.csv is deliberately NOT loaded: proven redundant (§2.2).

Usage:
    CALL bronze.load_bronze();
===============================================================================
*/
CREATE OR REPLACE PROCEDURE bronze.load_bronze()
LANGUAGE plpgsql
AS $$
DECLARE
    v_start      timestamptz;
    v_batch      timestamptz := clock_timestamp();
    v_rows       bigint;
BEGIN
    RAISE NOTICE '================================================';
    RAISE NOTICE 'Loading Bronze Layer';
    RAISE NOTICE '================================================';

    ---------------------------------------------------------------- summary_listings
    RAISE NOTICE '>> [Summary] bronze.summary_listings';
    v_start := clock_timestamp();
    TRUNCATE TABLE bronze.summary_listings;
    COPY bronze.summary_listings (id, name, host_id, host_profile_id, host_name, neighbourhood_group, neighbourhood, latitude, longitude, room_type, price, minimum_nights, number_of_reviews, last_review, reviews_per_month, calculated_host_listings_count, availability_365, number_of_reviews_ltm, license)
        FROM '/datasets/listings_summary.csv'
        WITH (FORMAT csv, HEADER true);
    SELECT count(*) INTO v_rows FROM bronze.summary_listings;
    RAISE NOTICE '   % rows in % ', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- detail_listings
    RAISE NOTICE '>> [Detail] bronze.detail_listings';
    v_start := clock_timestamp();
    TRUNCATE TABLE bronze.detail_listings;
    COPY bronze.detail_listings (id, listing_url, scrape_id, last_scraped, source, name, description, neighborhood_overview, picture_url, host_id, host_url, host_profile_id, host_profile_url, host_name, host_since, hosts_time_as_user_years, hosts_time_as_user_months, hosts_time_as_host_years, hosts_time_as_host_months, host_location, host_about, host_response_time, host_response_rate, host_acceptance_rate, host_is_superhost, host_thumbnail_url, host_picture_url, host_neighbourhood, host_listings_count, host_total_listings_count, host_verifications, host_has_profile_pic, host_identity_verified, neighbourhood, neighbourhood_cleansed, neighbourhood_group_cleansed, latitude, longitude, property_type, room_type, accommodates, bathrooms, bathrooms_text, bedrooms, beds, amenities, price, price_quote_checkin_date, price_quote_checkout_date, price_quote_total_price, price_quote_price_per_night, price_quote_raw, minimum_nights, maximum_nights, minimum_minimum_nights, maximum_minimum_nights, minimum_maximum_nights, maximum_maximum_nights, minimum_nights_avg_ntm, maximum_nights_avg_ntm, calendar_updated, has_availability, availability_30, availability_60, availability_90, availability_365, calendar_last_scraped, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, availability_eoy, number_of_reviews_ly, estimated_occupancy_l365d, estimated_revenue_l365d, first_review, last_review, review_scores_rating, review_scores_accuracy, review_scores_cleanliness, review_scores_checkin, review_scores_communication, review_scores_location, review_scores_value, license, instant_bookable, calculated_host_listings_count, calculated_host_listings_count_entire_homes, calculated_host_listings_count_private_rooms, calculated_host_listings_count_shared_rooms, reviews_per_month)
        FROM '/datasets/listings_detailed.csv'
        WITH (FORMAT csv, HEADER true);
    SELECT count(*) INTO v_rows FROM bronze.detail_listings;
    RAISE NOTICE '   % rows in % ', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- detail_reviews
    RAISE NOTICE '>> [Detail] bronze.detail_reviews';
    v_start := clock_timestamp();
    TRUNCATE TABLE bronze.detail_reviews;
    COPY bronze.detail_reviews (listing_id, id, date, reviewer_id, reviewer_name, comments)
        FROM '/datasets/reviews_detailed.csv'
        WITH (FORMAT csv, HEADER true);
    SELECT count(*) INTO v_rows FROM bronze.detail_reviews;
    RAISE NOTICE '   % rows in % ', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- neighbourhoods
    RAISE NOTICE '>> [Detail] bronze.neighbourhoods';
    v_start := clock_timestamp();
    TRUNCATE TABLE bronze.neighbourhoods;
    COPY bronze.neighbourhoods (neighbourhood_group, neighbourhood)
        FROM '/datasets/neighbourhoods.csv'
        WITH (FORMAT csv, HEADER true);
    SELECT count(*) INTO v_rows FROM bronze.neighbourhoods;
    RAISE NOTICE '   % rows in % ', v_rows, clock_timestamp() - v_start;

    ---------------------------------------------------------------- geojson
    RAISE NOTICE '>> [Geo] bronze.geo_neighbourhoods_raw';
    v_start := clock_timestamp();
    TRUNCATE TABLE bronze.geo_neighbourhoods_raw;
    -- pg_read_file() keeps the GeoJSON byte-raw in one jsonb value; COPY would
    -- misinterpret the document's internal commas and quoting.
    INSERT INTO bronze.geo_neighbourhoods_raw (doc)
    SELECT pg_read_file('/datasets/neighbourhoods.geojson')::jsonb;
    SELECT jsonb_array_length(doc -> 'features') INTO v_rows
      FROM bronze.geo_neighbourhoods_raw;
    RAISE NOTICE '   % features in % ', v_rows, clock_timestamp() - v_start;

    RAISE NOTICE '================================================';
    RAISE NOTICE 'Bronze load complete in %', clock_timestamp() - v_batch;
    RAISE NOTICE '================================================';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '!! BRONZE LOAD FAILED: % (SQLSTATE %)', SQLERRM, SQLSTATE;
    RAISE;
END;
$$;
