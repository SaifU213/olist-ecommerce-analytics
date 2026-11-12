-- =============================================================================
-- 04_analytics_views.sql
-- Business-question views on top of the star schema. Power BI imports
-- cohort_retention and customer_rfm; the notebook reads order_review_features.
--
-- "Valid" order = not Canceled/Unavailable and has at least one item
-- (same definition as the Power BI [Revenue] measure).
-- =============================================================================
DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;

CREATE VIEW analytics.valid_order_revenue AS
SELECT o.order_id,
       o.customer_unique_id,
       o.purchase_ts,
       date_trunc('month', o.purchase_ts)::date AS order_month,
       SUM(i.price)                             AS revenue,
       SUM(i.freight_value)                     AS freight,
       COUNT(*)                                 AS items
FROM dw.fact_orders o
JOIN dw.fact_order_items i USING (order_id)
WHERE o.order_status NOT IN ('Canceled', 'Unavailable')
GROUP BY o.order_id, o.customer_unique_id, o.purchase_ts;

-- -----------------------------------------------------------------------------
-- Q: How is revenue trending month over month and year over year?
-- A month spine from dim_date keeps LAG(…, 12) correct even for empty months.
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.monthly_revenue AS
WITH spine AS (
    SELECT DISTINCT month_start AS month
    FROM dw.dim_date
    WHERE month_start BETWEEN (SELECT MIN(order_month) FROM analytics.valid_order_revenue)
                          AND (SELECT MAX(order_month) FROM analytics.valid_order_revenue)
),
monthly AS (
    SELECT s.month,
           COUNT(v.order_id)                     AS orders,
           COUNT(DISTINCT v.customer_unique_id)  AS customers,
           COALESCE(SUM(v.revenue), 0)           AS revenue
    FROM spine s
    LEFT JOIN analytics.valid_order_revenue v ON v.order_month = s.month
    GROUP BY s.month
)
SELECT month,
       orders,
       customers,
       revenue,
       ROUND(revenue / NULLIF(orders, 0), 2)                                         AS avg_order_value,
       ROUND(100.0 * (revenue / NULLIF(LAG(revenue) OVER w, 0) - 1), 1)              AS mom_growth_pct,
       LAG(revenue, 12) OVER w                                                       AS revenue_same_month_ly,
       ROUND(100.0 * (revenue / NULLIF(LAG(revenue, 12) OVER w, 0) - 1), 1)          AS yoy_growth_pct,
       ROUND(AVG(revenue) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)      AS revenue_3m_moving_avg,
       SUM(revenue) OVER (w ROWS UNBOUNDED PRECEDING)                                AS cumulative_revenue
FROM monthly
WINDOW w AS (ORDER BY month);

-- -----------------------------------------------------------------------------
-- Q: Of the customers who first bought in month M, what share bought again
--    1, 2, 3 … months later?
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.cohort_retention AS
WITH customer_months AS (
    SELECT DISTINCT customer_unique_id, order_month
    FROM analytics.valid_order_revenue
),
cohorts AS (
    SELECT customer_unique_id, MIN(order_month) AS cohort_month
    FROM customer_months
    GROUP BY customer_unique_id
),
activity AS (
    SELECT c.cohort_month,
           (EXTRACT(year  FROM age(m.order_month, c.cohort_month)) * 12
          + EXTRACT(month FROM age(m.order_month, c.cohort_month)))::int AS months_since_first,
           COUNT(DISTINCT m.customer_unique_id)                          AS active_customers
    FROM customer_months m
    JOIN cohorts c USING (customer_unique_id)
    GROUP BY 1, 2
)
SELECT a.cohort_month,
       to_char(a.cohort_month, 'YYYY-MM')                                   AS cohort,
       a.months_since_first,
       FIRST_VALUE(a.active_customers) OVER (PARTITION BY a.cohort_month
                                             ORDER BY a.months_since_first) AS cohort_size,
       a.active_customers,
       ROUND(a.active_customers::numeric
             / FIRST_VALUE(a.active_customers) OVER (PARTITION BY a.cohort_month
                                                     ORDER BY a.months_since_first), 4) AS retention_rate
FROM activity a;

-- -----------------------------------------------------------------------------
-- Q: Which customers are worth targeting? RFM segmentation.
-- 97% of customers order once, so frequency is bucketed rather than NTILE'd.
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.customer_rfm AS
WITH as_of AS (
    SELECT MAX(purchase_ts)::date + 1 AS snapshot_date FROM analytics.valid_order_revenue
),
customer_stats AS (
    SELECT customer_unique_id,
           MAX(purchase_ts)::date AS last_purchase_date,
           MIN(purchase_ts)::date AS first_purchase_date,
           COUNT(*)               AS frequency,
           SUM(revenue)           AS monetary
    FROM analytics.valid_order_revenue
    GROUP BY customer_unique_id
),
scored AS (
    SELECT cs.*,
           a.snapshot_date - cs.last_purchase_date            AS recency_days,
           -- customer_unique_id breaks ties so every run assigns the same quintiles
           NTILE(5) OVER (ORDER BY cs.last_purchase_date, cs.customer_unique_id) AS r_score,  -- 5 = most recent
           CASE WHEN cs.frequency >= 3 THEN 5
                WHEN cs.frequency = 2  THEN 3
                ELSE 1 END                                                        AS f_score,
           NTILE(5) OVER (ORDER BY cs.monetary, cs.customer_unique_id)          AS m_score   -- 5 = biggest spenders
    FROM customer_stats cs
    CROSS JOIN as_of a
)
SELECT customer_unique_id,
       first_purchase_date,
       last_purchase_date,
       recency_days,
       frequency,
       ROUND(monetary, 2) AS monetary,
       r_score,
       f_score,
       m_score,
       CASE WHEN frequency >= 2 AND r_score >= 4 THEN '1. Active Repeat'
            WHEN frequency >= 2                  THEN '2. Lapsing Repeat'
            WHEN m_score = 5 AND r_score >= 3    THEN '3. High-Value New'
            WHEN r_score >= 4                    THEN '4. Recent New'
            WHEN m_score >= 4                    THEN '5. High-Value Lapsed'
            ELSE                                      '6. Low-Value Lapsed' END AS segment
FROM scored;

-- -----------------------------------------------------------------------------
-- Q: Who are the top sellers, and is revenue concentrated (Pareto)?
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.seller_ranking AS
WITH seller_orders AS (
    SELECT i.seller_id, i.order_id, SUM(i.price) AS revenue
    FROM dw.fact_order_items i
    JOIN dw.fact_orders o USING (order_id)
    WHERE o.order_status NOT IN ('Canceled', 'Unavailable')
    GROUP BY i.seller_id, i.order_id
),
totals AS (
    SELECT seller_id, COUNT(*) AS orders, SUM(revenue) AS revenue
    FROM seller_orders
    GROUP BY seller_id
),
service AS (
    SELECT so.seller_id,
           AVG(r.review_score)                                                         AS avg_review_score,
           AVG(o.is_late::int) FILTER (WHERE o.delivery_status <> 'Not Delivered')     AS late_rate,
           AVG(o.delivery_days)                                                        AS avg_delivery_days
    FROM seller_orders so
    JOIN dw.fact_orders o       USING (order_id)
    LEFT JOIN dw.fact_reviews r USING (order_id)
    GROUP BY so.seller_id
)
SELECT t.seller_id,
       s.city,
       s.state,
       s.region,
       t.orders,
       t.revenue,
       ROUND(t.revenue / t.orders, 2)                                   AS avg_order_value,
       ROUND(sv.avg_review_score, 2)                                    AS avg_review_score,
       ROUND(sv.late_rate, 4)                                           AS late_rate,
       ROUND(sv.avg_delivery_days, 1)                                   AS avg_delivery_days,
       RANK()   OVER (ORDER BY t.revenue DESC)                          AS revenue_rank,
       RANK()   OVER (PARTITION BY s.state ORDER BY t.revenue DESC)     AS rank_in_state,
       NTILE(4) OVER (ORDER BY t.revenue DESC)                          AS revenue_quartile,
       ROUND(100.0 * t.revenue / SUM(t.revenue) OVER (), 3)             AS revenue_share_pct,
       ROUND(100.0 * SUM(t.revenue) OVER (ORDER BY t.revenue DESC, t.seller_id
                                          ROWS UNBOUNDED PRECEDING)
                   / SUM(t.revenue) OVER (), 2)                         AS cumulative_share_pct
FROM totals t
JOIN dw.dim_seller s USING (seller_id)
LEFT JOIN service sv USING (seller_id);

-- -----------------------------------------------------------------------------
-- Q: Which categories drive revenue, and how satisfied are their buyers?
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.category_performance AS
WITH cat AS (
    SELECT p.category,
           COUNT(DISTINCT i.order_id)  AS orders,
           COUNT(*)                    AS items_sold,
           SUM(i.price)                AS revenue,
           SUM(i.freight_value)        AS freight
    FROM dw.fact_order_items i
    JOIN dw.fact_orders o  USING (order_id)
    JOIN dw.dim_product p  USING (product_id)
    WHERE o.order_status NOT IN ('Canceled', 'Unavailable')
    GROUP BY p.category
),
cat_reviews AS (
    SELECT p.category, AVG(r.review_score) AS avg_review_score
    FROM (SELECT DISTINCT order_id, product_id FROM dw.fact_order_items) i
    JOIN dw.dim_product p  USING (product_id)
    JOIN dw.fact_reviews r USING (order_id)
    GROUP BY p.category
)
SELECT c.category,
       c.orders,
       c.items_sold,
       c.revenue,
       ROUND(c.revenue / c.items_sold, 2)                   AS avg_item_price,
       ROUND(100.0 * c.freight / c.revenue, 1)              AS freight_pct_of_revenue,
       ROUND(r.avg_review_score, 2)                         AS avg_review_score,
       DENSE_RANK() OVER (ORDER BY c.revenue DESC)          AS revenue_rank,
       ROUND(100.0 * c.revenue / SUM(c.revenue) OVER (), 2) AS revenue_share_pct
FROM cat c
LEFT JOIN cat_reviews r USING (category);

-- -----------------------------------------------------------------------------
-- Q: Where is delivery slow, and does it show up in reviews?
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.delivery_by_state AS
SELECT c.state,
       st.state_name,
       c.region,
       COUNT(*)                                                      AS delivered_orders,
       ROUND(AVG(o.delivery_days), 1)                                AS avg_delivery_days,
       ROUND(AVG(o.days_vs_estimate), 1)                             AS avg_days_vs_estimate,
       ROUND(1 - AVG(o.is_late::int), 4)                             AS on_time_rate,
       ROUND(AVG(r.review_score), 2)                                 AS avg_review_score,
       RANK() OVER (ORDER BY AVG(o.delivery_days) DESC)              AS slowest_rank
FROM dw.fact_orders o
JOIN dw.dim_customer c  USING (customer_id)
JOIN dw.ref_state st    ON st.state = c.state
LEFT JOIN (SELECT order_id, AVG(review_score) AS review_score
           FROM dw.fact_reviews GROUP BY order_id) r USING (order_id)
WHERE o.delivery_status <> 'Not Delivered'
GROUP BY c.state, st.state_name, c.region;

-- -----------------------------------------------------------------------------
-- Modelling table for the statistics notebook: one row per delivered, reviewed order.
-- -----------------------------------------------------------------------------
CREATE VIEW analytics.order_review_features AS
WITH items AS (
    SELECT order_id,
           COUNT(*)                  AS n_items,
           COUNT(DISTINCT seller_id) AS n_sellers,
           SUM(price)                AS order_price,
           SUM(freight_value)        AS order_freight
    FROM dw.fact_order_items
    GROUP BY order_id
),
reviews AS (    -- 547 orders have several reviews; average them
    SELECT order_id, AVG(review_score)::numeric(3, 2) AS review_score
    FROM dw.fact_reviews
    GROUP BY order_id
)
SELECT o.order_id,
       o.purchase_date,
       c.state                                        AS customer_state,
       c.region                                       AS customer_region,
       o.delivery_days,
       o.estimated_delivery_date - o.purchase_date    AS promised_days,
       o.days_vs_estimate,
       o.is_late,
       i.n_items,
       i.n_sellers,
       i.order_price,
       i.order_freight,
       r.review_score,
       r.review_score <= 2                            AS is_negative_review
FROM dw.fact_orders o
JOIN items i           USING (order_id)
JOIN reviews r         USING (order_id)
JOIN dw.dim_customer c USING (customer_id)
WHERE o.delivery_status <> 'Not Delivered';
