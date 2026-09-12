/*
===============================================================================
DDL — Silver Layer
===============================================================================
Purpose:
    Cleaned, typed, standardised tables. Structure stays 1:1 with the source
    systems (decision A3): integration of summary + detail happens in Gold, so
    each Silver table remains traceable to exactly one source file.

    Applies defects D1, D2, D4, D7, D8, D9, D10, D11, D12, D13.
    D3, D5 and D6 are resolved in Gold, where the sources are joined.

    13 columns that are 100% NULL in the source (D9) are not carried here at all.

WARNING: Running this script DROPS and recreates every silver table.
===============================================================================
*/

-- --------------------------------------------------------------------------
-- silver.summary_listings  <- bronze.summary_listings
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.summary_listings CASCADE;
CREATE TABLE silver.summary_listings (
    listing_id                       BIGINT,                                                    -- PK
    listing_name                     TEXT,
    host_id                          BIGINT,
    host_profile_id                  BIGINT,
    host_name                        TEXT,
    neighbourhood                    TEXT,
    latitude                         NUMERIC(9,6),
    longitude                        NUMERIC(9,6),
    room_type                        TEXT,
    price                            NUMERIC(10,2),                                             -- D3 rounded - detail wins
    minimum_nights                   INT,
    number_of_reviews                INT,
    last_review                      DATE,
    reviews_per_month                NUMERIC(8,2),
    calculated_host_listings_count   INT,
    availability_365                 INT,
    number_of_reviews_ltm            INT,
    license                          TEXT,
    dwh_create_date                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_summary_listings PRIMARY KEY (listing_id)
);

-- --------------------------------------------------------------------------
-- silver.detail_listings  <- bronze.detail_listings
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.detail_listings CASCADE;
CREATE TABLE silver.detail_listings (
    listing_id                                     BIGINT,                                      -- PK
    listing_url                                    TEXT,
    scrape_id                                      BIGINT,
    scrape_date                                    DATE,                                        -- D1
    listing_source                                 TEXT,                                        -- D1 provenance
    listing_name                                   TEXT,
    description                                    TEXT,
    picture_url                                    TEXT,
    host_id                                        BIGINT,
    host_url                                       TEXT,
    host_profile_id                                BIGINT,
    host_profile_url                               TEXT,
    host_name                                      TEXT,
    host_years_as_user                             INT,
    host_months_as_user                            INT,
    host_years_as_host                             INT,
    host_months_as_host                            INT,
    host_location                                  TEXT,
    host_about                                     TEXT,
    host_is_superhost                              BOOLEAN,                                     -- D13
    host_picture_url                               TEXT,
    host_listings_count                            INT,
    host_has_profile_pic                           BOOLEAN,                                     -- D13
    host_identity_verified                         BOOLEAN,                                     -- D13
    neighbourhood                                  TEXT,
    latitude                                       NUMERIC(9,6),
    longitude                                      NUMERIC(9,6),
    property_type                                  TEXT,
    room_type                                      TEXT,
    accommodates                                   INT,
    bathrooms                                      NUMERIC(4,1),                                -- D8 - see proc
    bathrooms_is_derived                           BOOLEAN,                                     -- D8 transparency
    bathrooms_text                                 TEXT,
    bedrooms                                       INT,
    beds                                           INT,
    amenities                                      JSONB,                                       -- D7 raw kept for lineage
    price                                          NUMERIC(10,2),                               -- D2
    price_quote_checkin_date                       DATE,
    price_quote_checkout_date                      DATE,
    price_quote_total_price                        NUMERIC(12,2),
    price_quote_price_per_night                    NUMERIC(10,2),
    minimum_nights                                 INT,
    maximum_nights                                 INT,                                         -- D14 sentinel -> NULL
    has_unbounded_max_nights                       BOOLEAN,                                     -- D14
    is_minimum_nights_outlier                      BOOLEAN,                                     -- D12
    minimum_minimum_nights                         INT,
    maximum_minimum_nights                         INT,
    minimum_maximum_nights                         INT,                                         -- D14
    maximum_maximum_nights                         INT,                                         -- D14
    minimum_nights_avg_ntm                         NUMERIC(12,2),
    maximum_nights_avg_ntm                         NUMERIC(12,2),                               -- D14
    has_availability                               BOOLEAN,                                     -- D13
    availability_30                                INT,
    availability_60                                INT,
    availability_90                                INT,
    availability_365                               INT,
    availability_eoy                               INT,
    calendar_last_scraped                          DATE,
    number_of_reviews                              INT,
    number_of_reviews_ltm                          INT,
    number_of_reviews_l30d                         INT,
    number_of_reviews_ly                           INT,
    estimated_occupancy_l365d                      INT,
    estimated_revenue_l365d                        NUMERIC(12,2),
    first_review                                   DATE,
    last_review                                    DATE,
    review_scores_rating                           NUMERIC(4,2),                                -- D11 NULL is meaningful
    review_scores_accuracy                         NUMERIC(4,2),
    review_scores_cleanliness                      NUMERIC(4,2),
    review_scores_checkin                          NUMERIC(4,2),
    review_scores_communication                    NUMERIC(4,2),
    review_scores_location                         NUMERIC(4,2),
    review_scores_value                            NUMERIC(4,2),
    reviews_per_month                              NUMERIC(8,2),
    license                                        TEXT,
    calculated_host_listings_count                 INT,
    calculated_host_listings_count_entire_homes    INT,
    calculated_host_listings_count_private_rooms   INT,
    calculated_host_listings_count_shared_rooms    INT,
    dwh_create_date                                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_detail_listings PRIMARY KEY (listing_id)
);

-- --------------------------------------------------------------------------
-- silver.detail_reviews  <- bronze.detail_reviews
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.detail_reviews CASCADE;
CREATE TABLE silver.detail_reviews (
    review_id       BIGINT,                                                                     -- PK
    listing_id      BIGINT,                                                                     -- D6 FK
    review_date     DATE,
    reviewer_id     BIGINT,
    reviewer_name   TEXT,
    comments        TEXT,
    dwh_create_date TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_detail_reviews PRIMARY KEY (review_id)
);

-- --------------------------------------------------------------------------
-- silver.neighbourhoods   <- bronze.neighbourhoods + bronze.geo_neighbourhoods_raw
-- Lookup joined to its PostGIS boundary. neighbourhood_group dropped (D10).
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.neighbourhoods CASCADE;
CREATE TABLE silver.neighbourhoods (
    neighbourhood     TEXT PRIMARY KEY,
    geom              GEOMETRY(MultiPolygon, 4326),
    geom_was_repaired BOOLEAN NOT NULL,                    -- D15
    area_sqkm         NUMERIC(10,4),
    centroid_latitude  NUMERIC(9,6),
    centroid_longitude NUMERIC(9,6),
    dwh_create_date   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_neighbourhoods_geom ON silver.neighbourhoods USING GIST (geom);

-- --------------------------------------------------------------------------
-- silver.detail_listing_amenity   <- bronze.detail_listings.amenities  (D7)
-- The JSON array exploded into one row per listing-amenity pair.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.detail_listing_amenity CASCADE;
CREATE TABLE silver.detail_listing_amenity (
    listing_id        BIGINT NOT NULL,
    amenity           TEXT   NOT NULL,
    dwh_create_date   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_detail_listing_amenity PRIMARY KEY (listing_id, amenity)
);
CREATE INDEX idx_amenity_name ON silver.detail_listing_amenity (amenity);

-- Supporting indexes for the Gold joins
CREATE INDEX idx_detail_reviews_listing ON silver.detail_reviews (listing_id);
CREATE INDEX idx_detail_reviews_date    ON silver.detail_reviews (review_date);
CREATE INDEX idx_detail_listings_host   ON silver.detail_listings (host_id);
CREATE INDEX idx_detail_listings_neigh  ON silver.detail_listings (neighbourhood);
