-- =============================================================================
-- 03_transform.sql
-- staging (raw text) -> dw (typed star schema). Idempotent: the DDL script drops
-- and recreates dw, so this only inserts. Load order respects foreign keys.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Brazilian states -> region (IBGE macro-regions)
-- -----------------------------------------------------------------------------
INSERT INTO dw.ref_state (state, state_name, region) VALUES
    ('AC', 'Acre', 'North'),               ('AP', 'Amapá', 'North'),
    ('AM', 'Amazonas', 'North'),           ('PA', 'Pará', 'North'),
    ('RO', 'Rondônia', 'North'),           ('RR', 'Roraima', 'North'),
    ('TO', 'Tocantins', 'North'),
    ('AL', 'Alagoas', 'Northeast'),        ('BA', 'Bahia', 'Northeast'),
    ('CE', 'Ceará', 'Northeast'),          ('MA', 'Maranhão', 'Northeast'),
    ('PB', 'Paraíba', 'Northeast'),        ('PE', 'Pernambuco', 'Northeast'),
    ('PI', 'Piauí', 'Northeast'),          ('RN', 'Rio Grande do Norte', 'Northeast'),
    ('SE', 'Sergipe', 'Northeast'),
    ('DF', 'Distrito Federal', 'Center-West'), ('GO', 'Goiás', 'Center-West'),
    ('MT', 'Mato Grosso', 'Center-West'),  ('MS', 'Mato Grosso do Sul', 'Center-West'),
    ('ES', 'Espírito Santo', 'Southeast'), ('MG', 'Minas Gerais', 'Southeast'),
    ('RJ', 'Rio de Janeiro', 'Southeast'), ('SP', 'São Paulo', 'Southeast'),
    ('PR', 'Paraná', 'South'),             ('RS', 'Rio Grande do Sul', 'South'),
    ('SC', 'Santa Catarina', 'South');

-- -----------------------------------------------------------------------------
-- Calendar (full years so YoY comparisons have a complete prior year)
-- -----------------------------------------------------------------------------
INSERT INTO dw.dim_date
SELECT d::date                               AS date_key,
       EXTRACT(year FROM d)::smallint        AS year,
       'Q' || EXTRACT(quarter FROM d)        AS quarter,
       EXTRACT(month FROM d)::smallint       AS month_number,
       to_char(d, 'Mon')                     AS month_name,
       to_char(d, 'YYYY-MM')                 AS year_month,
       date_trunc('month', d)::date          AS month_start,
       EXTRACT(isodow FROM d)::smallint      AS weekday_number,
       to_char(d, 'Dy')                      AS weekday_name
FROM generate_series(date '2016-01-01', date '2018-12-31', interval '1 day') AS d;

-- -----------------------------------------------------------------------------
-- Geolocation: 1M noisy points -> one centroid per zip prefix.
-- Points outside Brazil's bounding box are data-entry errors and are dropped.
-- -----------------------------------------------------------------------------
INSERT INTO dw.dim_geolocation (zip_code_prefix, latitude, longitude)
SELECT geolocation_zip_code_prefix,
       round(avg(geolocation_lat::numeric), 6),
       round(avg(geolocation_lng::numeric), 6)
FROM staging.geolocation
WHERE geolocation_lat::numeric BETWEEN -34 AND 5.5
  AND geolocation_lng::numeric BETWEEN -74 AND -34
GROUP BY geolocation_zip_code_prefix;

-- -----------------------------------------------------------------------------
-- Customers & sellers
-- -----------------------------------------------------------------------------
INSERT INTO dw.dim_customer
SELECT c.customer_id,
       c.customer_unique_id,
       c.customer_zip_code_prefix,
       initcap(c.customer_city),
       c.customer_state,
       s.region,
       g.latitude,
       g.longitude
FROM staging.customers c
JOIN dw.ref_state s            ON s.state = c.customer_state
LEFT JOIN dw.dim_geolocation g ON g.zip_code_prefix = c.customer_zip_code_prefix;

INSERT INTO dw.dim_seller
SELECT sl.seller_id,
       sl.seller_zip_code_prefix,
       initcap(sl.seller_city),
       sl.seller_state,
       s.region,
       g.latitude,
       g.longitude
FROM staging.sellers sl
JOIN dw.ref_state s            ON s.state = sl.seller_state
LEFT JOIN dw.dim_geolocation g ON g.zip_code_prefix = sl.seller_zip_code_prefix;

-- -----------------------------------------------------------------------------
-- Products. Two categories used by products are missing from Olist's own
-- translation file, so they are patched here.
-- -----------------------------------------------------------------------------
WITH translation AS (
    SELECT product_category_name AS category_pt, product_category_name_english AS category_en
    FROM staging.category_translation
    UNION ALL
    VALUES ('pc_gamer', 'pc_gamer'),
           ('portateis_cozinha_e_preparadores_de_alimentos', 'kitchen_portables_and_food_preparers')
)
INSERT INTO dw.dim_product
SELECT p.product_id,
       NULLIF(p.product_category_name, ''),
       COALESCE(initcap(replace(t.category_en, '_', ' ')), 'Uncategorized'),
       NULLIF(p.product_name_lenght, '')::integer,
       NULLIF(p.product_description_lenght, '')::integer,
       NULLIF(p.product_photos_qty, '')::integer,
       NULLIF(p.product_weight_g, '')::integer,
       NULLIF(p.product_length_cm, '')::integer,
       NULLIF(p.product_height_cm, '')::integer,
       NULLIF(p.product_width_cm, '')::integer
FROM staging.products p
LEFT JOIN translation t ON t.category_pt = p.product_category_name;

-- -----------------------------------------------------------------------------
-- Orders: delivery metrics + each customer's order sequence (window function)
-- -----------------------------------------------------------------------------
WITH typed AS (
    SELECT o.order_id,
           o.customer_id,
           c.customer_unique_id,
           initcap(o.order_status)                                    AS order_status,
           o.order_purchase_timestamp::timestamp                       AS purchase_ts,
           NULLIF(o.order_approved_at, '')::timestamp                  AS approved_ts,
           NULLIF(o.order_delivered_carrier_date, '')::timestamp       AS carrier_handoff_ts,
           NULLIF(o.order_delivered_customer_date, '')::timestamp      AS delivered_ts,
           o.order_estimated_delivery_date::timestamp::date            AS estimated_delivery_date
    FROM staging.orders o
    JOIN dw.dim_customer c ON c.customer_id = o.customer_id
)
INSERT INTO dw.fact_orders
SELECT order_id,
       customer_id,
       customer_unique_id,
       order_status,
       purchase_ts,
       approved_ts,
       carrier_handoff_ts,
       delivered_ts,
       estimated_delivery_date,
       purchase_ts::date,
       round(EXTRACT(epoch FROM delivered_ts - purchase_ts) / 86400.0, 2),
       delivered_ts::date - estimated_delivery_date,
       CASE WHEN delivered_ts IS NULL                         THEN 'Not Delivered'
            WHEN delivered_ts::date > estimated_delivery_date THEN 'Late'
            ELSE 'On Time' END,
       COALESCE(delivered_ts::date > estimated_delivery_date, false),
       ROW_NUMBER() OVER w,
       CASE WHEN ROW_NUMBER() OVER w = 1 THEN 'New' ELSE 'Returning' END
FROM typed
WINDOW w AS (PARTITION BY customer_unique_id ORDER BY purchase_ts, order_id);

-- -----------------------------------------------------------------------------
-- Order items, payments, reviews
-- -----------------------------------------------------------------------------
INSERT INTO dw.fact_order_items (order_id, order_item_seq, product_id, seller_id,
                                 shipping_limit_ts, price, freight_value)
SELECT order_id,
       order_item_id::smallint,
       product_id,
       seller_id,
       shipping_limit_date::timestamp,
       price::numeric(10, 2),
       freight_value::numeric(10, 2)
FROM staging.order_items;

INSERT INTO dw.fact_payments
SELECT order_id,
       payment_sequential::smallint,
       initcap(replace(payment_type, '_', ' ')),
       payment_installments::smallint,
       payment_value::numeric(10, 2)
FROM staging.order_payments;

INSERT INTO dw.fact_reviews
SELECT review_id,
       order_id,
       review_score::smallint,
       NULLIF(review_comment_title, ''),
       NULLIF(review_comment_message, ''),
       review_creation_date::timestamp::date,
       NULLIF(review_answer_timestamp, '')::timestamp,
       CASE WHEN review_score::int >= 4 THEN 'Positive'
            WHEN review_score::int = 3  THEN 'Neutral'
            ELSE 'Negative' END,
       NULLIF(review_comment_message, '') IS NOT NULL
FROM staging.order_reviews;
