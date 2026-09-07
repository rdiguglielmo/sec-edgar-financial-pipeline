"""Load the SEC quarterly tab separated files into the DuckDB raw layer.

The raw layer is a faithful copy of the source. Every column is stored as text,
empty fields stay empty instead of becoming NULL, and nothing is renamed,
reordered or deduplicated. Typing and cleaning belong to the dbt staging models,
where they are visible and testable; guessing types at load time would silently
strip the leading zeros from identifiers such as cik and fye.

One quarter is about 644 MB once uncompressed, so the members are streamed out
of the ZIP in record batches and handed to DuckDB one batch at a time. Nothing
is unpacked to disk and the archives are only ever opened for reading.

The four quarters are stacked into one table per member file. The quarter each
row came from is recorded in _source_file, so no information is lost by
stacking and the staging models read one table per source file rather than a
union of sixteen.

Loading is idempotent per source file: the rows previously loaded from a given
member are deleted and reinserted within a single transaction, so re-running the
script leaves the same row counts rather than duplicating them.

Usage:
    python src/load_raw.py
"""

from __future__ import annotations

import logging
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import duckdb
import pyarrow as pa
from pyarrow import csv as pyarrow_csv

from config import (
    ARCHIVE_MEMBERS,
    DUCKDB_PATH,
    QUARTERS,
    RAW_DIR,
    RAW_SCHEMA,
)

LOGGER = logging.getLogger("load_raw")

# Ingestion metadata carried by every raw table, in the order it is appended.
METADATA_COLUMNS = ("_source_file", "_ingested_at", "_batch_id")
METADATA_DDL = "_source_file VARCHAR, _ingested_at TIMESTAMP, _batch_id VARCHAR"

# Size of the uncompressed chunk pyarrow turns into one record batch. Large
# enough that the per batch overhead is negligible on a 530 MB file, small
# enough that peak memory stays flat regardless of the file being read.
READ_BLOCK_BYTES = 32 * 1024 * 1024

# Name of the temporary DuckDB view the record batch stream is bound to.
STREAM_VIEW = "tsv_stream"


def _column_names(archive: zipfile.ZipFile, member: str) -> list[str]:
    """Return the column names declared in the header line of a member file.

    The names have to be known before the file is parsed, because they are what
    pins every column to VARCHAR. Only the first block of the member is
    decompressed to get them.
    """
    with archive.open(member) as stream:
        buffer = b""
        while b"\n" not in buffer:
            chunk = stream.read(8192)
            if not chunk:
                break
            buffer += chunk
    header = buffer.split(b"\n", 1)[0].decode("utf-8").rstrip("\r")
    return header.split("\t")


def _open_batch_reader(stream, column_names: list[str]) -> pyarrow_csv.CSVStreamingReader:
    """Return a record batch reader over an open tab separated stream.

    Double quotes are honoured as quoting rather than treated as ordinary text.
    The SEC does escape values that contain the delimiter: in the 2025q1
    num.txt, thirty rows carry a literal tab inside the segments value and wrap
    the whole field in double quotes to protect it. Reading those quotes as
    plain characters shifts every field after segments by one position, which is
    corruption that no later test would catch.

    Embedded newlines are rejected on purpose. The SEC declares one record per
    line, so a value that breaks that promise should stop the load rather than
    quietly merge two rows into one.
    """
    return pyarrow_csv.open_csv(
        stream,
        read_options=pyarrow_csv.ReadOptions(
            block_size=READ_BLOCK_BYTES,
            encoding="utf-8",
        ),
        parse_options=pyarrow_csv.ParseOptions(
            delimiter="\t",
            quote_char='"',
            double_quote=True,
            newlines_in_values=False,
        ),
        convert_options=pyarrow_csv.ConvertOptions(
            # Every column as text, and an empty field left as an empty string
            # rather than promoted to NULL: empty and absent are different facts
            # and the raw layer is not the place to decide which one this is.
            column_types={name: pa.string() for name in column_names},
            strings_can_be_null=False,
        ),
    )


def _ensure_table(
    connection: duckdb.DuckDBPyConnection, table: str, column_names: list[str]
) -> None:
    """Create the raw table on first sight, or check it still matches the file.

    A quarter whose header differs from the one that created the table would
    otherwise load with the extra columns dropped and the missing ones filled
    with NULL, which is the kind of loss that only surfaces much later.
    """
    existing = [
        row[0]
        for row in connection.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position",
            [RAW_SCHEMA, table],
        ).fetchall()
    ]

    if not existing:
        columns = ", ".join(f'"{name}" VARCHAR' for name in column_names)
        connection.execute(
            f'CREATE TABLE "{RAW_SCHEMA}"."{table}" ({columns}, {METADATA_DDL})'
        )
        return

    expected = [*column_names, *METADATA_COLUMNS]
    if existing != expected:
        raise ValueError(
            f"{RAW_SCHEMA}.{table} has columns {existing}, but the file being "
            f"loaded declares {expected}. Drop the table and reload rather than "
            f"mixing layouts."
        )


def load_member(
    connection: duckdb.DuckDBPyConnection,
    archive: zipfile.ZipFile,
    archive_name: str,
    member: str,
    batch_id: str,
    ingested_at: datetime,
) -> int:
    """Load one member file of one archive and return the number of rows loaded.

    The delete and the insert run in one transaction, so an interrupted load
    leaves the table holding either the previous copy of this source file or the
    new one, never a partial mixture of the two.
    """
    table = member
    source_file = f"{archive_name}/{member}.txt"
    column_names = _column_names(archive, f"{member}.txt")
    _ensure_table(connection, table, column_names)

    connection.execute("BEGIN TRANSACTION")
    try:
        connection.execute(
            f'DELETE FROM "{RAW_SCHEMA}"."{table}" WHERE _source_file = ?',
            [source_file],
        )
        with archive.open(f"{member}.txt") as stream:
            connection.register(STREAM_VIEW, _open_batch_reader(stream, column_names))
            try:
                rows = connection.execute(
                    f'INSERT INTO "{RAW_SCHEMA}"."{table}" BY NAME '
                    f"SELECT *, ? AS _source_file, ? AS _ingested_at, ? AS _batch_id "
                    f"FROM {STREAM_VIEW}",
                    [source_file, ingested_at, batch_id],
                ).fetchone()[0]
            finally:
                connection.unregister(STREAM_VIEW)
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise

    LOGGER.info("%-24s %10d rows", source_file, rows)
    return rows


def load_quarter(
    connection: duckdb.DuckDBPyConnection,
    archive_path: Path,
    batch_id: str,
    ingested_at: datetime,
) -> int:
    """Load the four member files of one quarterly archive."""
    with zipfile.ZipFile(archive_path) as archive:
        return sum(
            load_member(
                connection, archive, archive_path.name, member, batch_id, ingested_at
            )
            for member in ARCHIVE_MEMBERS
        )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    missing = [q for q in QUARTERS if not (RAW_DIR / f"{q}.zip").exists()]
    if missing:
        raise FileNotFoundError(
            f"Missing archives in {RAW_DIR}: {', '.join(missing)}. "
            f"Run python src/extract.py first."
        )

    ingested_at = datetime.now(timezone.utc)
    batch_id = ingested_at.strftime("%Y%m%dT%H%M%SZ")
    LOGGER.info("Batch %s into %s", batch_id, DUCKDB_PATH)

    DUCKDB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with duckdb.connect(DUCKDB_PATH) as connection:
        connection.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW_SCHEMA}"')

        total = 0
        for quarter in QUARTERS:
            total += load_quarter(
                connection, RAW_DIR / f"{quarter}.zip", batch_id, ingested_at
            )

        LOGGER.info("%d rows loaded in this batch", total)
        for member in ARCHIVE_MEMBERS:
            held = connection.execute(
                f'SELECT count(*) FROM "{RAW_SCHEMA}"."{member}"'
            ).fetchone()[0]
            LOGGER.info("%s.%-4s holds %10d rows", RAW_SCHEMA, member, held)


if __name__ == "__main__":
    main()
