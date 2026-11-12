-- =============================================================================
-- 02_warehouse_ddl.sql
-- Star schema ("dw") that Power BI imports.
--
--   dim_date ─┐                       ┌─ dim_product
--   dim_customer ─► fact_orders ◄─ fact_order_items ─► dim_seller
--                     ▲      ▲
--         fact_payments      fact_reviews
--
-- Grain
--   fact_orders       1 row per order          (order-level delivery metrics)
--   fact_order_items  1 row per item in order  (revenue grain)
--   fact_payments     1 row per payment record
--   fact_reviews      1 row per review         (review_id alone is NOT unique)
-- =============================================================================
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- -----------------------------------------------------------------------------
-- Reference / dimensions
-- -----------------------------------------------------------------------------
CREATE TABLE dw.ref_state (
    state       char(2)     PRIMARY KEY,
    state_name  text        NOT NULL,
    region      text        NOT NULL
        CHECK (region IN ('North', 'Northeast', 'Center-West', 'Southeast', 'South'))
);

CREATE TABLE dw.dim_date (
    date_key      date        PRIMARY KEY,
    year          smallint    NOT NULL,
    quarter       char(2)     NOT NULL,          -- 'Q1'..'Q4'
    month_number  smallint    NOT NULL CHECK (month_number BETWEEN 1 AND 12),
    month_name    char(3)     NOT NULL,          -- 'Jan'..'Dec'
    year_month    char(7)     NOT NULL,          -- '2017-01'
    month_start   date        NOT NULL,
    weekday_number smallint   NOT NULL CHECK (weekday_number BETWEEN 1 AND 7),  -- 1 = Monday
    weekday_name  char(3)     NOT NULL
);

CREATE TABLE dw.dim_geolocation (
    zip_code_prefix char(5)       PRIMARY KEY,
    latitude        numeric(9, 6) NOT NULL,
    longitude       numeric(9, 6) NOT NULL
);

CREATE TABLE dw.dim_customer (
    customer_id        varchar(32)   PRIMARY KEY,   -- one per order (Olist quirk)
    customer_unique_id varchar(32)   NOT NULL,      -- the actual person
    zip_code_prefix    char(5)       NOT NULL,
    city               text          NOT NULL,
    state              char(2)       NOT NULL REFERENCES dw.ref_state (state),
    region             text          NOT NULL,
    latitude           numeric(9, 6),               -- NULL when zip not in geolocation file
    longitude          numeric(9, 6)
);
CREATE INDEX ix_dim_customer_unique ON dw.dim_customer (customer_unique_id);

CREATE TABLE dw.dim_seller (
    seller_id       varchar(32)   PRIMARY KEY,
    zip_code_prefix char(5)       NOT NULL,
    city            text          NOT NULL,
    state           char(2)       NOT NULL REFERENCES dw.ref_state (state),
    region          text          NOT NULL,
    latitude        numeric(9, 6),
    longitude       numeric(9, 6)
);

CREATE TABLE dw.dim_product (
    product_id         varchar(32) PRIMARY KEY,
    category_pt        text,                         -- NULL for 610 products
    category           text        NOT NULL,         -- English, 'Uncategorized' fallback
    name_length        integer,
    description_length integer,
    photos             integer,
    weight_g           integer CHECK (weight_g >= 0),
    length_cm          integer CHECK (length_cm >= 0),
    height_cm          integer CHECK (height_cm >= 0),
    width_cm           integer CHECK (width_cm >= 0)
);

-- -----------------------------------------------------------------------------
-- Facts
-- -----------------------------------------------------------------------------
CREATE TABLE dw.fact_orders (
    order_id                varchar(32) PRIMARY KEY,
    customer_id             varchar(32) NOT NULL REFERENCES dw.dim_customer (customer_id),
    customer_unique_id      varchar(32) NOT NULL,     -- denormalised for fast distinct counts
    order_status            text        NOT NULL,
    purchase_ts             timestamp   NOT NULL,
    approved_ts             timestamp,
    carrier_handoff_ts      timestamp,
    delivered_ts            timestamp,
    estimated_delivery_date date        NOT NULL,
    purchase_date           date        NOT NULL REFERENCES dw.dim_date (date_key),
    delivery_days           numeric(7, 2),            -- purchase -> customer, fractional days
    days_vs_estimate        integer,                  -- > 0 means late
    delivery_status         text        NOT NULL
        CHECK (delivery_status IN ('On Time', 'Late', 'Not Delivered')),
    is_late                 boolean     NOT NULL,
    customer_order_seq      integer     NOT NULL CHECK (customer_order_seq >= 1),
    customer_type           text        NOT NULL CHECK (customer_type IN ('New', 'Returning')),
    CHECK (delivered_ts IS NULL OR delivered_ts >= purchase_ts - interval '1 day')
);
CREATE INDEX ix_fact_orders_customer ON dw.fact_orders (customer_id);
CREATE INDEX ix_fact_orders_unique   ON dw.fact_orders (customer_unique_id, purchase_ts);
CREATE INDEX ix_fact_orders_date     ON dw.fact_orders (purchase_date);

CREATE TABLE dw.fact_order_items (
    order_id          varchar(32)    NOT NULL REFERENCES dw.fact_orders (order_id),
    order_item_seq    smallint       NOT NULL,
    product_id        varchar(32)    NOT NULL REFERENCES dw.dim_product (product_id),
    seller_id         varchar(32)    NOT NULL REFERENCES dw.dim_seller (seller_id),
    shipping_limit_ts timestamp      NOT NULL,
    price             numeric(10, 2) NOT NULL CHECK (price >= 0),
    freight_value     numeric(10, 2) NOT NULL CHECK (freight_value >= 0),
    item_total        numeric(10, 2) GENERATED ALWAYS AS (price + freight_value) STORED,
    PRIMARY KEY (order_id, order_item_seq)
);
CREATE INDEX ix_fact_items_product ON dw.fact_order_items (product_id);
CREATE INDEX ix_fact_items_seller  ON dw.fact_order_items (seller_id);

CREATE TABLE dw.fact_payments (
    order_id      varchar(32)    NOT NULL REFERENCES dw.fact_orders (order_id),
    payment_seq   smallint       NOT NULL,
    payment_type  text           NOT NULL,
    installments  smallint       NOT NULL CHECK (installments >= 0),
    payment_value numeric(10, 2) NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_seq)
);

CREATE TABLE dw.fact_reviews (
    review_id        varchar(32) NOT NULL,
    order_id         varchar(32) NOT NULL REFERENCES dw.fact_orders (order_id),
    review_score     smallint    NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title    text,
    comment_message  text,
    review_date      date        NOT NULL,
    answer_ts        timestamp,
    sentiment        text        NOT NULL CHECK (sentiment IN ('Positive', 'Neutral', 'Negative')),
    has_comment      boolean     NOT NULL,
    PRIMARY KEY (review_id, order_id)
);
CREATE INDEX ix_fact_reviews_order ON dw.fact_reviews (order_id);
