"""
Data-quality tests for the warehouse. Run after etl/load_warehouse.py:

    pytest -q

Uses the same PG* environment variables as the ETL. Database name defaults to
"olist" (override with OLIST_DB).
"""
import os

import psycopg
import pytest

DB = os.environ.get("OLIST_DB", "olist")


@pytest.fixture(scope="session")
def db():
    try:
        conn = psycopg.connect(dbname=DB, autocommit=True)
    except psycopg.OperationalError as exc:
        pytest.skip(f"cannot connect to database {DB!r}: {exc}")
    yield conn
    conn.close()


def scalar(db, query):
    return db.execute(query).fetchone()[0]


# --- completeness: nothing silently dropped between staging and dw ----------

@pytest.mark.parametrize("staging, dw", [
    ("orders", "fact_orders"),
    ("order_items", "fact_order_items"),
    ("order_payments", "fact_payments"),
    ("order_reviews", "fact_reviews"),
    ("customers", "dim_customer"),
    ("sellers", "dim_seller"),
    ("products", "dim_product"),
])
def test_row_counts_match_staging(db, staging, dw):
    assert scalar(db, f"SELECT COUNT(*) FROM staging.{staging}") == scalar(db, f"SELECT COUNT(*) FROM dw.{dw}")


def test_money_reconciles_to_source(db):
    assert scalar(db, "SELECT SUM(price::numeric) FROM staging.order_items") == \
           scalar(db, "SELECT SUM(price) FROM dw.fact_order_items")
    assert scalar(db, "SELECT SUM(payment_value::numeric) FROM staging.order_payments") == \
           scalar(db, "SELECT SUM(payment_value) FROM dw.fact_payments")


# --- business rules ----------------------------------------------------------

def test_every_product_has_a_category(db):
    assert scalar(db, "SELECT COUNT(*) FROM dw.dim_product WHERE category IS NULL") == 0
    # only products with no Portuguese category end up Uncategorized (translation gaps are patched)
    assert scalar(db, "SELECT COUNT(*) FROM dw.dim_product WHERE category = 'Uncategorized' "
                      "AND category_pt IS NOT NULL") == 0


def test_one_new_order_per_customer(db):
    new_orders = scalar(db, "SELECT COUNT(*) FROM dw.fact_orders WHERE customer_type = 'New'")
    people = scalar(db, "SELECT COUNT(DISTINCT customer_unique_id) FROM dw.fact_orders")
    assert new_orders == people


def test_late_flag_matches_status(db):
    assert scalar(db, "SELECT COUNT(*) FROM dw.fact_orders "
                      "WHERE is_late <> (delivery_status = 'Late')") == 0


def test_every_order_date_in_calendar(db):
    assert scalar(db, "SELECT COUNT(*) FROM dw.fact_orders o "
                      "LEFT JOIN dw.dim_date d ON d.date_key = o.purchase_date WHERE d.date_key IS NULL") == 0


# --- analytics views ---------------------------------------------------------

def test_revenue_matches_reference(db):
    # independently computed with pandas from the raw CSVs
    revenue = scalar(db, "SELECT SUM(revenue) FROM analytics.valid_order_revenue")
    assert round(float(revenue)) == 13_494_401


def test_monthly_revenue_has_no_gaps(db):
    months, span = db.execute("""
        SELECT COUNT(*),
               (EXTRACT(year FROM age(MAX(month), MIN(month))) * 12
              + EXTRACT(month FROM age(MAX(month), MIN(month))))::int + 1
        FROM analytics.monthly_revenue""").fetchone()
    assert months == span


def test_cohort_month_zero_is_full_retention(db):
    assert scalar(db, "SELECT COUNT(*) FROM analytics.cohort_retention "
                      "WHERE months_since_first = 0 AND retention_rate <> 1") == 0


def test_rfm_one_row_per_customer(db):
    assert scalar(db, "SELECT COUNT(*) FROM analytics.customer_rfm") == \
           scalar(db, "SELECT COUNT(DISTINCT customer_unique_id) FROM analytics.customer_rfm")


def test_rfm_segments_are_deterministic(db):
    # NTILE splits ties arbitrarily unless the ORDER BY is unique; two reads must agree
    query = "SELECT segment, COUNT(*) FROM analytics.customer_rfm GROUP BY segment ORDER BY segment"
    assert db.execute(query).fetchall() == db.execute(query).fetchall()


def test_seller_pareto_reaches_100(db):
    assert float(scalar(db, "SELECT MAX(cumulative_share_pct) FROM analytics.seller_ranking")) == pytest.approx(100, abs=0.01)
