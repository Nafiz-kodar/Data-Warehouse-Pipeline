/*
===============================================================================
DDL — Bronze Layer
===============================================================================
Purpose:
    Defines the raw landing tables. Every column is TEXT on purpose: Bronze must
    never fail a load on a type error, and must preserve the source byte-for-byte
    ($347.40, 't'/'f', JSON-in-a-string). All casting happens in Silver.

    Column order matches each source CSV exactly — COPY depends on it.

Source systems (decision A3):
    summary_*  Inside Airbnb summary export
    detail_*   Inside Airbnb detailed export

WARNING: Running this script DROPS and recreates every bronze table.
===============================================================================
*/

-- ------------------------------------------------------------------------
-- bronze.summary_listings  <-  datasets/listings_summary.csv  (19 columns)
-- ------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.summary_listings CASCADE;
CREATE TABLE bronze.summary_listings (
    id                                             TEXT,
    name                                           TEXT,
    host_id                                        TEXT,
    host_profile_id                                TEXT,
    host_name                                      TEXT,
    neighbourhood_group                            TEXT,
    neighbourhood                                  TEXT,
    latitude                                       TEXT,
    longitude                                      TEXT,
    room_type                                      TEXT,
    price                                          TEXT,
    minimum_nights                                 TEXT,
    number_of_reviews                              TEXT,
    last_review                                    TEXT,
    reviews_per_month                              TEXT,
    calculated_host_listings_count                 TEXT,
    availability_365                               TEXT,
    number_of_reviews_ltm                          TEXT,
    license                                        TEXT
);

-- ------------------------------------------------------------------------
-- bronze.detail_listings  <-  datasets/listings_detailed.csv  (90 columns)
-- ------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.detail_listings CASCADE;
CREATE TABLE bronze.detail_listings (
    id                                             TEXT,
    listing_url                                    TEXT,
    scrape_id                                      TEXT,
    last_scraped                                   TEXT,
    source                                         TEXT,
    name                                           TEXT,
    description                                    TEXT,
    neighborhood_overview                          TEXT,
    picture_url                                    TEXT,
    host_id                                        TEXT,
    host_url                                       TEXT,
    host_profile_id                                TEXT,
    host_profile_url                               TEXT,
    host_name                                      TEXT,
    host_since                                     TEXT,
    hosts_time_as_user_years                       TEXT,
    hosts_time_as_user_months                      TEXT,
    hosts_time_as_host_years                       TEXT,
    hosts_time_as_host_months                      TEXT,
    host_location                                  TEXT,
    host_about                                     TEXT,
    host_response_time                             TEXT,
    host_response_rate                             TEXT,
    host_acceptance_rate                           TEXT,
    host_is_superhost                              TEXT,
    host_thumbnail_url                             TEXT,
    host_picture_url                               TEXT,
    host_neighbourhood                             TEXT,
    host_listings_count                            TEXT,
    host_total_listings_count                      TEXT,
    host_verifications                             TEXT,
    host_has_profile_pic                           TEXT,
    host_identity_verified                         TEXT,
    neighbourhood                                  TEXT,
    neighbourhood_cleansed                         TEXT,
    neighbourhood_group_cleansed                   TEXT,
    latitude                                       TEXT,
    longitude                                      TEXT,
    property_type                                  TEXT,
    room_type                                      TEXT,
    accommodates                                   TEXT,
    bathrooms                                      TEXT,
    bathrooms_text                                 TEXT,
    bedrooms                                       TEXT,
    beds                                           TEXT,
    amenities                                      TEXT,
    price                                          TEXT,
    price_quote_checkin_date                       TEXT,
    price_quote_checkout_date                      TEXT,
    price_quote_total_price                        TEXT,
    price_quote_price_per_night                    TEXT,
    price_quote_raw                                TEXT,
    minimum_nights                                 TEXT,
    maximum_nights                                 TEXT,
    minimum_minimum_nights                         TEXT,
    maximum_minimum_nights                         TEXT,
    minimum_maximum_nights                         TEXT,
    maximum_maximum_nights                         TEXT,
    minimum_nights_avg_ntm                         TEXT,
    maximum_nights_avg_ntm                         TEXT,
    calendar_updated                               TEXT,
    has_availability                               TEXT,
    availability_30                                TEXT,
    availability_60                                TEXT,
    availability_90                                TEXT,
    availability_365                               TEXT,
    calendar_last_scraped                          TEXT,
    number_of_reviews                              TEXT,
    number_of_reviews_ltm                          TEXT,
    number_of_reviews_l30d                         TEXT,
    availability_eoy                               TEXT,
    number_of_reviews_ly                           TEXT,
    estimated_occupancy_l365d                      TEXT,
    estimated_revenue_l365d                        TEXT,
    first_review                                   TEXT,
    last_review                                    TEXT,
    review_scores_rating                           TEXT,
    review_scores_accuracy                         TEXT,
    review_scores_cleanliness                      TEXT,
    review_scores_checkin                          TEXT,
    review_scores_communication                    TEXT,
    review_scores_location                         TEXT,
    review_scores_value                            TEXT,
    license                                        TEXT,
    instant_bookable                               TEXT,
    calculated_host_listings_count                 TEXT,
    calculated_host_listings_count_entire_homes    TEXT,
    calculated_host_listings_count_private_rooms   TEXT,
    calculated_host_listings_count_shared_rooms    TEXT,
    reviews_per_month                              TEXT
);

-- ------------------------------------------------------------------------
-- bronze.detail_reviews  <-  datasets/reviews_detailed.csv  (6 columns)
-- ------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.detail_reviews CASCADE;
CREATE TABLE bronze.detail_reviews (
    listing_id                                     TEXT,
    id                                             TEXT,
    date                                           TEXT,
    reviewer_id                                    TEXT,
    reviewer_name                                  TEXT,
    comments                                       TEXT
);

-- ------------------------------------------------------------------------
-- bronze.neighbourhoods  <-  datasets/neighbourhoods.csv  (2 columns)
-- ------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.neighbourhoods CASCADE;
CREATE TABLE bronze.neighbourhoods (
    neighbourhood_group                            TEXT,
    neighbourhood                                  TEXT
);

-- ------------------------------------------------------------------------
-- bronze.geo_neighbourhoods_raw  <-  datasets/neighbourhoods.geojson
-- Stored as a single untouched jsonb document. Silver unnests it with
-- jsonb_array_elements and converts geometry via ST_GeomFromGeoJSON (decision A2).
-- ------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.geo_neighbourhoods_raw CASCADE;
CREATE TABLE bronze.geo_neighbourhoods_raw (
    doc                                            JSONB
);
