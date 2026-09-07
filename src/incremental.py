"""Incremental stage: discover filings published since the bulk load.

The quarterly archives loaded by load_raw.py are a bulk snapshot that the SEC
republishes about a quarter behind. This stage closes that gap by asking the
SEC's submissions API what each company in the scope has filed since, landing
that index in raw.filing_index, and moving a watermark forward.

What this stage does and does not carry
---------------------------------------
https://data.sec.gov/submissions/CIK##########.json publishes filing metadata:
the accession number, the form, the dates, the primary document. It does not
publish the reported figures. Those keep arriving in the quarterly archives, so
a newly discovered 10-K cannot become a fact until the archive covering it is
downloaded. The run therefore ends by naming the archives that are now missing,
which is the actionable output of an incremental discovery run against a source
that publishes its numbers in batches.

The watermark
-------------
etl.etl_watermark holds one row per company rather than one row for the source.
Each company is a separate request, and a single shared watermark advanced past
a company whose request failed would skip that company's filings permanently.
One row per endpoint keeps the failure contained to the endpoint.

A company with no watermark row is seeded from the bulk load: the latest
acceptance timestamp already present in raw.sub for that company. That is what
makes this an incremental run rather than a first load, and it is the only place
the two stages are joined.

The seed needs a timezone correction that is easy to miss. The submissions API
dates acceptance in UTC to the second; sub.txt records the same event in US
Eastern time rounded to the nearest minute. The same McDonald's 10-Q reads
2025-11-05T20:06:57Z in one and 2025-11-05 15:07:00 in the other. Rounding can
place the recorded value up to 30 seconds after the true one, so the seed is
pulled back by WATERMARK_SAFETY_MARGIN_SECONDS. The boundary then always errs
towards reading a filing twice instead of skipping one, and reading twice costs
nothing because the write is an upsert.

Idempotency
-----------
Rows are written by deleting the incoming keys and reinserting them inside one
transaction that also moves the watermark, so a run either lands completely or
not at all. The table carries a primary key on (cik, accession_number), which
makes a duplicate impossible at storage level rather than merely unlikely.

Running twice therefore cannot duplicate a row for two independent reasons, and
a plain second run only exercises the weaker one: it selects nothing, because
the watermark has moved past everything. That proves the filter, not the write.

--replay proves the write. It discards the stored watermark and starts from the
seed again, so the same run is repeated over the same window and every row is
written a second time. The row count has to come back identical.

Usage:
    python src/incremental.py
    python src/incremental.py --replay
"""

from __future__ import annotations

import argparse
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import duckdb

from config import (
    DUCKDB_PATH,
    ETL_SCHEMA,
    FILING_INDEX_TABLE,
    QUARTERS,
    RAW_SCHEMA,
    SCOPE_CIKS,
    SEC_SOURCE_TIMEZONE,
    SEC_SUBMISSIONS_URL_TEMPLATE,
    WATERMARK_SAFETY_MARGIN_SECONDS,
    WATERMARK_TABLE,
)
from sec_client import sec_get

LOGGER = logging.getLogger("incremental")

# Columns landed from filings.recent, as (JSON field, column name). Every source
# column is stored as text, on the same terms as the four archive tables: typing
# belongs to the staging layer where it is visible and testable. size and the
# three XBRL flags arrive as numbers in the JSON and are stored as text for that
# reason, not by accident.
FILING_FIELDS = (
    ("accessionNumber", "accession_number"),
    ("form", "form_type"),
    ("filingDate", "filing_date"),
    ("acceptanceDateTime", "acceptance_datetime"),
    ("reportDate", "report_date"),
    ("act", "act"),
    ("fileNumber", "file_number"),
    ("items", "items"),
    ("core_type", "core_type"),
    ("primaryDocument", "primary_document"),
    ("primaryDocDescription", "primary_doc_description"),
    ("size", "file_size"),
    ("isXBRL", "is_xbrl"),
    ("isInlineXBRL", "is_inline_xbrl"),
    ("isXBRLNumeric", "is_xbrl_numeric"),
)

COLUMN_NAMES = tuple(column for _, column in FILING_FIELDS)

# Forms that carry the financial statements this pipeline models. Used only to
# report which quarterly archives are now worth downloading. No row is filtered
# on it: raw.filing_index lands every form the API returns.
FINANCIAL_STATEMENT_FORMS = ("10-K", "10-Q")

def _parse_api_timestamp(value: str) -> datetime:
    """Parse an acceptanceDateTime into a naive UTC datetime.

    The API publishes 2026-08-04T11:44:19.000Z. Everything downstream stores and
    compares naive UTC, so the offset is applied and dropped here rather than in
    each caller.
    """
    return datetime.fromisoformat(value).astimezone(timezone.utc).replace(tzinfo=None)


def ensure_tables(connection: duckdb.DuckDBPyConnection) -> None:
    """Create the watermark and the filing index if they are not there yet."""
    connection.execute(f'CREATE SCHEMA IF NOT EXISTS "{ETL_SCHEMA}"')
    connection.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW_SCHEMA}"')

    connection.execute(
        f"""
        CREATE TABLE IF NOT EXISTS "{ETL_SCHEMA}"."{WATERMARK_TABLE}" (
            -- One row per endpoint read, which here is one per company.
            source_name                 VARCHAR PRIMARY KEY,
            -- Latest acceptance timestamp written, naive UTC. The next run
            -- selects strictly after this.
            last_accepted_at            TIMESTAMP NOT NULL,
            -- Rows written by the run that last touched this source, not a
            -- running total: a run that finds nothing records zero.
            filings_loaded_last_run     BIGINT NOT NULL,
            updated_at                  TIMESTAMP NOT NULL,
            batch_id                    VARCHAR NOT NULL
        )
        """
    )

    columns = ", ".join(f'"{name}" VARCHAR' for name in COLUMN_NAMES)
    connection.execute(
        f"""
        CREATE TABLE IF NOT EXISTS "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}" (
            cik VARCHAR NOT NULL,
            {columns},
            _source_file VARCHAR,
            _ingested_at TIMESTAMP,
            _batch_id VARCHAR,
            -- The grain is one filing as indexed under one company, not one
            -- filing. A submission can be indexed under more than one company:
            -- a joint filing lists both registrants, and an ownership form filed
            -- by an institution is indexed under the issuer it concerns. Keying
            -- on the accession number alone would reject those.
            PRIMARY KEY (cik, accession_number)
        )
        """
    )


def read_watermarks(connection: duckdb.DuckDBPyConnection) -> dict[str, datetime]:
    """Return the stored watermark per source name."""
    rows = connection.execute(
        f'SELECT source_name, last_accepted_at FROM "{ETL_SCHEMA}"."{WATERMARK_TABLE}"'
    ).fetchall()
    return {name: value for name, value in rows}


def seed_watermark(connection: duckdb.DuckDBPyConnection, cik: str) -> datetime | None:
    """Derive a starting watermark for a company from the bulk loaded archives.

    Returns None when the company has no filing in the raw layer at all, which
    means there is nothing to be incremental to and the caller should load the
    whole index the API offers.
    """
    row = connection.execute(
        f'SELECT max(accepted) FROM "{RAW_SCHEMA}"."sub" WHERE lpad(cik, 10, \'0\') = ?',
        [cik],
    ).fetchone()
    if not row or row[0] is None:
        return None

    # sub.txt stores the timestamp as 2025-11-05 15:07:00.0 in US Eastern time.
    eastern = datetime.strptime(str(row[0])[:19], "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=ZoneInfo(SEC_SOURCE_TIMEZONE)
    )
    as_utc = eastern.astimezone(timezone.utc).replace(tzinfo=None)
    return as_utc - timedelta(seconds=WATERMARK_SAFETY_MARGIN_SECONDS)


def fetch_submissions(cik: str) -> dict:
    """Return the submissions document for one company.

    A 404 here means the cik reached the endpoint without its left padding to
    ten digits, which sec_client raises rather than retries: the request will
    never start working, and the fix is in the caller.
    """
    url = SEC_SUBMISSIONS_URL_TEMPLATE.format(cik=cik)
    return sec_get(url).json()


def index_rows(document: dict) -> list[dict[str, str]]:
    """Return filings.recent as a list of rows keyed by column name.

    The API stores the index column wise, one parallel array per field, so it is
    transposed here. Absent optional fields are read as empty strings rather than
    nulls, which is the same convention the archive loader follows.
    """
    recent = document["filings"]["recent"]
    row_count = len(recent["accessionNumber"])
    columns = {
        column: recent.get(field, [""] * row_count) for field, column in FILING_FIELDS
    }
    return [
        {column: "" if values[i] is None else str(values[i]) for column, values in columns.items()}
        for i in range(row_count)
    ]


def assert_index_reaches_watermark(
    cik: str, rows: list[dict[str, str]], watermark: datetime
) -> None:
    """Fail when filings.recent does not reach back as far as the watermark.

    The document holds the most recent filings inline and older ones in separate
    files listed under filings.files, which this stage does not read. That is
    safe only while the inline block still covers the period since the last run.
    A prolific filer could push it out of range, and the failure mode would be a
    silent gap rather than an error, so it is asserted instead.

    Measured on the ten companies of the scope: the inline block reaches back to
    between 2010 and 2019, against watermarks in late 2025.
    """
    oldest = min(_parse_api_timestamp(row["acceptance_datetime"]) for row in rows)
    if oldest > watermark:
        raise RuntimeError(
            f"CIK {cik}: the submissions index starts at {oldest} but the "
            f"watermark is {watermark}. Filings between the two are in the "
            f"paged files this stage does not read, so the run would leave a "
            f"gap. Reload the bulk archives or extend this stage to follow "
            f"filings.files."
        )


def load_company(
    connection: duckdb.DuckDBPyConnection,
    cik: str,
    rows: list[dict[str, str]],
    watermark: datetime,
    batch_id: str,
    ingested_at: datetime,
) -> int:
    """Write one company's new filings and move its watermark, atomically.

    The delete, the insert and the watermark update share a transaction. A run
    interrupted between the insert and the watermark would otherwise leave a
    watermark claiming rows that are not there, and the next run would start
    after them.
    """
    source_name = f"submissions/CIK{cik}"
    source_file = SEC_SUBMISSIONS_URL_TEMPLATE.format(cik=cik)

    placeholders = ", ".join("?" for _ in COLUMN_NAMES)
    column_list = ", ".join(f'"{name}"' for name in COLUMN_NAMES)

    incoming_columns = ", ".join(f'"{name}" VARCHAR' for name in COLUMN_NAMES)
    connection.execute(f"CREATE OR REPLACE TEMP TABLE incoming ({incoming_columns})")
    if rows:
        connection.executemany(
            f"INSERT INTO incoming ({column_list}) VALUES ({placeholders})",
            [tuple(row[name] for name in COLUMN_NAMES) for row in rows],
        )

    highest = max(
        (_parse_api_timestamp(row["acceptance_datetime"]) for row in rows),
        default=watermark,
    )

    connection.execute("BEGIN TRANSACTION")
    try:
        connection.execute(
            f'DELETE FROM "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}" t '
            f"USING incoming i "
            f"WHERE t.cik = ? AND t.accession_number = i.accession_number",
            [cik],
        )
        connection.execute(
            f'INSERT INTO "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}" '
            f"(cik, {column_list}, _source_file, _ingested_at, _batch_id) "
            f"SELECT ?, {column_list}, ?, ?, ? FROM incoming",
            [cik, source_file, ingested_at, batch_id],
        )
        connection.execute(
            f'INSERT INTO "{ETL_SCHEMA}"."{WATERMARK_TABLE}" '
            f"(source_name, last_accepted_at, filings_loaded_last_run, updated_at, batch_id) "
            f"VALUES (?, ?, ?, ?, ?) "
            f"ON CONFLICT (source_name) DO UPDATE SET "
            f"last_accepted_at = excluded.last_accepted_at, "
            f"filings_loaded_last_run = excluded.filings_loaded_last_run, "
            f"updated_at = excluded.updated_at, "
            f"batch_id = excluded.batch_id",
            [source_name, highest, len(rows), ingested_at, batch_id],
        )
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise

    return len(rows)


def missing_archives(connection: duckdb.DuckDBPyConnection) -> list[str]:
    """Return the quarterly archives the indexed financial filings now need.

    A discovered 10-K or 10-Q carries no figures until the archive covering the
    quarter it was filed in has been downloaded and loaded. This is the pointer
    from the discovery run to the next extract run.
    """
    forms = ", ".join(f"'{form}'" for form in FINANCIAL_STATEMENT_FORMS)
    rows = connection.execute(
        f"""
        SELECT DISTINCT
            strftime(strptime(filing_date, '%Y-%m-%d'), '%Y')
                || 'q' || quarter(strptime(filing_date, '%Y-%m-%d'))::varchar AS archive
        FROM "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}"
        WHERE form_type IN ({forms})
        ORDER BY archive
        """
    ).fetchall()
    return [archive for (archive,) in rows if archive not in QUARTERS]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--replay",
        action="store_true",
        help=(
            "Discard the stored watermark and start from the seed again, so the "
            "same window is selected and written a second time. Row counts have "
            "to stay identical: this is what proves the write is idempotent "
            "rather than the filter in front of it."
        ),
    )
    arguments = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if not DUCKDB_PATH.exists():
        raise FileNotFoundError(
            f"No warehouse at {DUCKDB_PATH}. Run python src/load_raw.py first: "
            f"the watermark is seeded from the filings the bulk load landed."
        )

    ingested_at = datetime.now(timezone.utc).replace(tzinfo=None)
    batch_id = ingested_at.strftime("%Y%m%dT%H%M%SZ")
    mode = "replaying from the seed" if arguments.replay else "since the watermark"
    LOGGER.info("Batch %s, %s, %d companies", batch_id, mode, len(SCOPE_CIKS))

    with duckdb.connect(DUCKDB_PATH) as connection:
        ensure_tables(connection)
        stored = {} if arguments.replay else read_watermarks(connection)

        total_offered = 0
        total_loaded = 0
        for cik in SCOPE_CIKS:
            source_name = f"submissions/CIK{cik}"
            watermark = stored.get(source_name) or seed_watermark(connection, cik)
            if watermark is None:
                # No bulk history for this company, so everything the index
                # offers is new. Only reachable for a company added to the scope
                # after the archives were loaded.
                watermark = datetime.min
                LOGGER.info("%s has no bulk history, loading the whole index", cik)

            document = fetch_submissions(cik)
            rows = index_rows(document)
            assert_index_reaches_watermark(cik, rows, watermark)

            selected = [
                row
                for row in rows
                if _parse_api_timestamp(row["acceptance_datetime"]) > watermark
            ]

            loaded = load_company(
                connection, cik, selected, watermark, batch_id, ingested_at
            )
            total_offered += len(rows)
            total_loaded += loaded
            LOGGER.info(
                "%s  watermark %s  offered %4d  selected %4d",
                cik,
                watermark.isoformat(sep=" ", timespec="seconds"),
                len(rows),
                loaded,
            )

        held = connection.execute(
            f'SELECT count(*) FROM "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}"'
        ).fetchone()[0]
        LOGGER.info(
            "%d filings offered, %d written, %s.%s holds %d",
            total_offered,
            total_loaded,
            RAW_SCHEMA,
            FILING_INDEX_TABLE,
            held,
        )

        by_form = connection.execute(
            f'SELECT form_type, count(*) FROM "{RAW_SCHEMA}"."{FILING_INDEX_TABLE}" '
            f"GROUP BY 1 ORDER BY 2 DESC LIMIT 5"
        ).fetchall()
        LOGGER.info(
            "Most indexed forms: %s",
            ", ".join(f"{form} {count}" for form, count in by_form),
        )

        pending = missing_archives(connection)
        if pending:
            LOGGER.info(
                "Financial filings are indexed for archives not yet downloaded: %s. "
                "The submissions API publishes metadata, not figures, so those "
                "filings carry no facts until config.QUARTERS covers them and "
                "extract.py and load_raw.py have run again.",
                ", ".join(pending),
            )
        else:
            LOGGER.info("Every indexed 10-K and 10-Q falls inside a loaded archive")


if __name__ == "__main__":
    main()
