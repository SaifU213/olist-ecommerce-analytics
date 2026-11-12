"""
Load the Olist CSVs into PostgreSQL and build the star schema.

    staging (raw text, bulk COPY)  ->  dw (typed star schema)  ->  analytics (views)

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGUSER, PGPASSWORD), so no credentials live in the code.

Usage:
    python etl/load_warehouse.py                     # data/ folder, database "olist"
    python etl/load_warehouse.py --data-dir path/to/csvs --database olist
"""
from __future__ import annotations

import argparse
import logging
import time
import zipfile
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"

# staging table -> source file
SOURCES = {
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
    "geolocation": "olist_geolocation_dataset.csv",
}

# Scripts that build the warehouse; run together in one transaction.
BUILD_SCRIPTS = ["02_warehouse_ddl.sql", "03_transform.sql", "04_analytics_views.sql"]

log = logging.getLogger("etl")


def ensure_data(data_dir: Path, archive: Path) -> None:
    """Unzip the Kaggle archive if the CSVs are not there yet."""
    missing = [f for f in SOURCES.values() if not (data_dir / f).exists()]
    if not missing:
        return
    if not archive.exists():
        raise FileNotFoundError(f"Missing {missing} in {data_dir} and no archive at {archive}")
    log.info("Extracting %s -> %s", archive.name, data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        for name in SOURCES.values():
            zf.extract(name, data_dir)


def ensure_database(dbname: str) -> None:
    """Create the target database if it does not exist (needs CREATEDB privilege)."""
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)).fetchone()
        if not exists:
            log.info("Creating database %s", dbname)
            conn.execute(sql.SQL("CREATE DATABASE {} ENCODING 'UTF8'").format(sql.Identifier(dbname)))


def run_script(conn: psycopg.Connection, name: str) -> None:
    started = time.perf_counter()
    conn.execute((SQL_DIR / name).read_text(encoding="utf-8"))
    log.info("  %-26s %6.1fs", name, time.perf_counter() - started)


def load_staging(conn: psycopg.Connection, data_dir: Path) -> dict[str, int]:
    """Bulk-load each CSV with COPY. CSV mode handles quoted multi-line review comments."""
    counts = {}
    for table, filename in SOURCES.items():
        started = time.perf_counter()
        copy_sql = sql.SQL("COPY {} FROM STDIN WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')").format(
            sql.Identifier("staging", table))
        with conn.cursor() as cur:
            with cur.copy(copy_sql) as copy, open(data_dir / filename, "rb") as f:
                while chunk := f.read(1 << 20):
                    copy.write(chunk)
            counts[table] = cur.rowcount
        log.info("  staging.%-22s %9s rows %6.1fs", table, f"{counts[table]:,}", time.perf_counter() - started)
    return counts


def summarize(conn: psycopg.Connection) -> None:
    rows = conn.execute("""
        SELECT table_schema || '.' || table_name
        FROM information_schema.tables
        WHERE table_schema = 'dw' AND table_type = 'BASE TABLE'
        ORDER BY table_name""").fetchall()
    log.info("Warehouse row counts:")
    for (name,) in rows:
        schema, table = name.split(".")
        n = conn.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(schema, table))).fetchone()[0]
        log.info("  %-28s %9s", name, f"{n:,}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument("--archive", type=Path, default=ROOT / "archive.zip")
    parser.add_argument("--database", default="olist")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

    started = time.perf_counter()
    ensure_data(args.data_dir, args.archive)
    ensure_database(args.database)

    with psycopg.connect(dbname=args.database) as conn:
        log.info("Loading staging")
        run_script(conn, "01_staging.sql")
        load_staging(conn, args.data_dir)
        conn.commit()

        log.info("Building warehouse")
        for script in BUILD_SCRIPTS:        # one transaction: all or nothing
            run_script(conn, script)
        conn.commit()

        conn.autocommit = True
        conn.execute("ANALYZE")
        summarize(conn)

    log.info("Done in %.1fs", time.perf_counter() - started)


if __name__ == "__main__":
    main()
