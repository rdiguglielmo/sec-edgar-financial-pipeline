"""Shared configuration for the SEC EDGAR pipeline.

Every stage of the pipeline reads its paths, source URLs and access rules from
here, so that changing the quarters under analysis or the location of the raw
layer is a one line edit rather than a search across scripts.
"""

from __future__ import annotations

import csv
import os
from pathlib import Path

from dotenv import load_dotenv

# Paths are derived from this file's location rather than the working directory,
# so the scripts behave the same whether they are run from the repository root,
# from src/, or through the Makefile.
PROJECT_ROOT = Path(__file__).resolve().parents[1]

DATA_DIR = PROJECT_ROOT / "data"
RAW_DIR = DATA_DIR / "raw"
DB_DIR = DATA_DIR / "db"
OUTPUT_PARQUET_DIR = PROJECT_ROOT / "output" / "parquet"

# Warehouse
# ---------
# A single DuckDB file under data/db/, rebuilt from data/raw/ by the pipeline
# and therefore not versioned. dbt reads and writes the same file.
DUCKDB_PATH = DB_DIR / "sec_edgar.duckdb"

RAW_SCHEMA = "raw"

# The star schema, built by dbt and exported to Parquet for Power BI.
MARTS_SCHEMA = "marts"

# Pipeline bookkeeping lives apart from the data it tracks, so that dropping and
# rebuilding the raw layer does not take the watermark with it.
ETL_SCHEMA = "etl"
WATERMARK_TABLE = "etl_watermark"

# History of the data quality suite: one row per check per run, appended rather
# than overwritten, so that a check's result can be compared against its own
# past instead of only being visible for the current run.
DQ_RESULTS_TABLE = "dq_check_results"

# dbt writes run_results.json and manifest.json here after every invocation.
# They are the source of the quality history: the results are read from what dbt
# actually ran, never typed in. The directory is not versioned, so the table is
# populated on the machine that ran the tests.
DBT_DIR = PROJECT_ROOT / "dbt"
DBT_TARGET_DIR = DBT_DIR / "target"

# Landing table for the incremental stage. It sits in the raw schema because it
# is source data with ingestion metadata, on the same terms as the four archive
# tables: every source column is text, and typing happens in staging.
FILING_INDEX_TABLE = "filing_index"

# The four tab separated members of every quarterly archive, ordered smallest
# first so that a malformed archive is caught on a two megabyte file rather than
# half a gigabyte into the load. The member name without its extension is also
# the name of the raw table it lands in.
ARCHIVE_MEMBERS = ("sub", "tag", "pre", "num")

load_dotenv(PROJECT_ROOT / ".env")

# Source
# ------
# Financial Statement Data Sets, published quarterly by the SEC as one ZIP per
# quarter. Landing page:
# https://www.sec.gov/data-research/sec-markets-data/financial-statement-data-sets
SEC_ZIP_URL_TEMPLATE = (
    "https://www.sec.gov/files/dera/data/financial-statement-data-sets/{quarter}.zip"
)

# Calendar year 2025: recent, and closed, so the archives will not change while
# the pipeline is being built.
QUARTERS = ("2025q1", "2025q2", "2025q3", "2025q4")

# Complementary source for the incremental stage. One JSON document per company,
# holding the index of everything it has filed. It publishes filing metadata, not
# reported figures: the numbers keep arriving in the quarterly archives above,
# roughly a quarter behind. The cik has to be left padded to ten digits or the
# endpoint answers 404, and sub.txt ships it unpadded.
SEC_SUBMISSIONS_URL_TEMPLATE = "https://data.sec.gov/submissions/CIK{cik}.json"

# The submissions document dates acceptance in UTC to the second, while sub.txt
# records the same event in US Eastern time rounded to the nearest minute:
# 2025-11-05T20:06:57Z against 2025-11-05 15:07:00. Rounding can push the
# recorded value up to 30 seconds past the true one, so a watermark seeded from
# sub.txt is pulled back by this margin. The boundary then always re-reads a
# filing rather than risking a skip, and re-reading is free because the write is
# an upsert on the natural key.
SEC_SOURCE_TIMEZONE = "America/New_York"
WATERMARK_SAFETY_MARGIN_SECONDS = 60

# Access policy
# -------------
# The SEC rejects automated requests that do not identify the caller by name and
# email, answering HTTP 403, and asks clients to stay under 10 requests per
# second. Both rules are documented at https://www.sec.gov/os/webmaster-faq
SEC_USER_AGENT = os.getenv("SEC_USER_AGENT", "").strip()

SEC_MAX_REQUESTS_PER_SECOND = 10
SEC_MIN_REQUEST_INTERVAL_SECONDS = 1 / SEC_MAX_REQUESTS_PER_SECOND

# Transfer settings for the quarterly archives, which run up to about 122 MB.
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 60


# Analytical scope
# ----------------
# The pipeline loads every filing the SEC published in 2025. The analysis is
# limited to one industry, so that operating margins are comparable across the
# companies being charted. Criteria, rejected alternatives and the query that
# selects these ten are in docs/scope.md and analysis/00_scope_selection.sql.
# Two codes, because the SEC's own classification splits one industry in two and
# the filer picks which side it lands on: McDonald's and Chipotle report 5812,
# Starbucks and Wendy's report 5810. Filtering on either alone drops direct
# competitors of companies that stay in.
SCOPE_SIC_CODES = ("5810", "5812")  # Retail, eating and drinking places

# The ten companies live in a dbt seed rather than in this file, and this file
# reads them from there. dbt cannot read Python, so the alternative was the same
# list written twice, in two languages, with nothing to keep them in step. A
# roster that disagrees with itself does not fail: the marts quietly analyse a
# different set of companies than the extractor refreshes.
SCOPE_SEED_PATH = PROJECT_ROOT / "dbt" / "seeds" / "scope_companies.csv"


def _read_scope_ciks() -> tuple[str, ...]:
    """Return the scope identifiers in the documented order, largest first.

    Values are already zero padded to ten digits in the seed, which is the form
    the SEC's submissions API expects at
    https://data.sec.gov/submissions/CIK##########.json. Note that sub.txt ships
    cik unpadded; see the identifier section of docs/data_quality.md.
    """
    with SCOPE_SEED_PATH.open(encoding="utf-8", newline="") as handle:
        rows = sorted(csv.DictReader(handle), key=lambda row: int(row["scope_rank"]))
    return tuple(row["cik"] for row in rows)


SCOPE_CIKS = _read_scope_ciks()


def sec_headers() -> dict[str, str]:
    """Return the HTTP headers required by the SEC, or fail with an explanation.

    There is no usable default for the User-Agent: a placeholder value would
    turn a missing configuration into an unexplained 403 partway through a run,
    so the absence is reported here instead.
    """
    if not SEC_USER_AGENT:
        raise RuntimeError(
            "SEC_USER_AGENT is not set. Copy .env.example to .env and fill in "
            "your name and email. The SEC answers 403 to requests that do not "
            "identify the caller."
        )
    return {"User-Agent": SEC_USER_AGENT}
