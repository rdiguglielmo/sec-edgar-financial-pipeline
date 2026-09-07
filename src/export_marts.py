"""Export stage: write the marts to Parquet for Power BI.

DuckDB has no Power BI connector. Power BI cannot open the warehouse file, so
the star schema is copied to Parquet, which Power BI reads natively through
Get Data. That copy is a stage of the pipeline rather than a manual step, which
is why it lives here and not in a note in the README.

The files are committed, and that is the point of them
-----------------------------------------------------
Anyone evaluating this repository has to see the result without installing
Python, downloading 400 MB from the SEC or building anything. The exported
Parquet is the smallest artefact that carries the actual output. It costs
around 1.9 MB for the whole star schema, so the limit that would normally rule
this out does not apply here.

GitHub rejects any file over 100 MiB, and the check below enforces it before
git can. Today the largest file is the fact at about 1.8 MB, a margin of
roughly fifty five fold, and two thirds of that file is its two hashed key
columns rather than the figures. The check is not there for today: it is there
for the day the analytical scope is widened, when the failure would otherwise
surface as a rejected push after the commit is already written. The full
unfiltered fact is around 640 MB; see section 8 of docs/modeling_decisions.md.

Snappy rather than zstd
-----------------------
zstd produces smaller files, and DuckDB writes it happily. Power BI's Parquet
connector has read Snappy for as long as it has existed and zstd only in recent
versions. At this size the saving is measured in kilobytes and the risk is a
dashboard that will not refresh on someone else's machine, so the older and
duller codec wins.

Read only
---------
The warehouse is opened read only, on the same terms as profile_raw.py.
Exporting must never be the reason a figure changed. Writing the Parquet files
themselves is unaffected: they are outside the database.

Usage:
    python src/export_marts.py
"""

from __future__ import annotations

import logging

import duckdb

from config import (
    DQ_RESULTS_TABLE,
    DUCKDB_PATH,
    ETL_SCHEMA,
    MARTS_SCHEMA,
    OUTPUT_PARQUET_DIR,
)

LOGGER = logging.getLogger("export_marts")

# The star schema: five dimensions and one fact, each with the key it is sorted
# on. scope_companies also lives in the marts schema but is not exported: it is
# the roster the marts are built from, an input rather than an output, and
# dim_company already carries every company it names.
#
# The sort is not cosmetic. A table is an unordered set of rows, and DuckDB
# returns them in whatever order the rebuild happened to produce, so exporting
# twice from identical data was measured to write different bytes for three of
# the six models. These files are committed, so that turns every pipeline run
# into a diff on files whose contents did not change, and a reader can no longer
# tell a real change from a reshuffle. Sorting on the key makes the bytes depend
# on the data alone.
MART_RELATIONS = (
    ("dim_company", "company_key"),
    ("dim_filing", "filing_key"),
    ("dim_account", "account_key"),
    ("dim_statement", "display_order"),
    ("dim_date", "date_key"),
    ("fct_financial_facts", "fact_key"),
)

# The quality history is exported alongside the star schema because the
# dashboard has a data quality page and Power BI has no other way to read it.
# It is optional: the table only exists once dbt test has run and
# load_dq_results.py has landed a batch, and a warehouse that has not been
# tested yet should still export its marts.
OPTIONAL_RELATIONS = ((ETL_SCHEMA, DQ_RESULTS_TABLE, "batch_id, check_name"),)

# GitHub refuses a file over 100 MiB outright and warns over 50 MiB.
GITHUB_HARD_LIMIT_BYTES = 100 * 1024 * 1024
GITHUB_WARNING_BYTES = 50 * 1024 * 1024

# Snappy, deliberately. See the module docstring.
PARQUET_COMPRESSION = "SNAPPY"


def relation_exists(connection: duckdb.DuckDBPyConnection, schema: str, name: str) -> bool:
    """Return whether a table or view of that name exists in that schema."""
    row = connection.execute(
        """
        SELECT count(*)
        FROM information_schema.tables
        WHERE table_schema = ? AND table_name = ?
        """,
        [schema, name],
    ).fetchone()
    return bool(row and row[0])


def export_relation(
    connection: duckdb.DuckDBPyConnection, schema: str, name: str, order_by: str
) -> tuple[int, int]:
    """Write one relation to Parquet and return its row count and file size.

    The row count is read back out of the written file rather than taken from
    the source query. A truncated or partially written file is the failure mode
    worth catching here, and it is the one a count taken before the write would
    miss.
    """
    target = OUTPUT_PARQUET_DIR / f"{name}.parquet"

    source_rows = connection.execute(f'SELECT count(*) FROM "{schema}"."{name}"').fetchone()[0]

    connection.execute(
        f"""
        COPY (SELECT * FROM "{schema}"."{name}" ORDER BY {order_by})
        TO '{target.as_posix()}'
        (FORMAT PARQUET, COMPRESSION {PARQUET_COMPRESSION})
        """
    )

    written_rows = connection.execute(
        "SELECT count(*) FROM read_parquet(?)", [target.as_posix()]
    ).fetchone()[0]

    if written_rows != source_rows:
        raise RuntimeError(
            f"{name}.parquet holds {written_rows:,} rows, the source has {source_rows:,}. "
            f"The file is incomplete and must not be committed."
        )

    size_bytes = target.stat().st_size

    if size_bytes > GITHUB_HARD_LIMIT_BYTES:
        raise RuntimeError(
            f"{target.name} is {size_bytes / 1024 / 1024:.1f} MiB, over GitHub's 100 MiB "
            f"limit. The export is committed so the repository can be read without "
            f"running anything; a file this size cannot be. Narrow the analytical scope "
            f"or stop committing this file, and say which in the README."
        )
    if size_bytes > GITHUB_WARNING_BYTES:
        LOGGER.warning(
            "%s is %.1f MiB. GitHub warns over 50 MiB and refuses over 100 MiB.",
            target.name,
            size_bytes / 1024 / 1024,
        )

    return written_rows, size_bytes


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if not DUCKDB_PATH.exists():
        raise FileNotFoundError(
            f"No warehouse at {DUCKDB_PATH}. Run python src/load_raw.py and then "
            f"dbt run, which is what builds the marts this stage exports."
        )

    OUTPUT_PARQUET_DIR.mkdir(parents=True, exist_ok=True)

    relations = [(MARTS_SCHEMA, name, order_by) for name, order_by in MART_RELATIONS]

    with duckdb.connect(DUCKDB_PATH, read_only=True) as connection:
        missing = [
            name for schema, name, _ in relations if not relation_exists(connection, schema, name)
        ]
        if missing:
            raise RuntimeError(
                f"Missing from the {MARTS_SCHEMA} schema: {', '.join(missing)}. "
                f"Run dbt seed and dbt run before exporting."
            )

        for schema, name, order_by in OPTIONAL_RELATIONS:
            if relation_exists(connection, schema, name):
                relations.append((schema, name, order_by))
            else:
                LOGGER.warning(
                    "%s.%s not found, skipping. Run dbt test and then "
                    "python src/load_dq_results.py to give the dashboard its "
                    "data quality page.",
                    schema,
                    name,
                )

        total_bytes = 0
        for schema, name, order_by in relations:
            rows, size_bytes = export_relation(connection, schema, name, order_by)
            total_bytes += size_bytes
            LOGGER.info("%-28s %10s rows %9.1f KB", f"{name}.parquet", f"{rows:,}", size_bytes / 1024)

    LOGGER.info(
        "%d files in %s, %.1f KB total",
        len(relations),
        OUTPUT_PARQUET_DIR,
        total_bytes / 1024,
    )


if __name__ == "__main__":
    main()
