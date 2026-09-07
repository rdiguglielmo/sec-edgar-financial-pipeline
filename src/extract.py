"""Download the SEC EDGAR quarterly Financial Statement Data Sets.

Each quarter is published as a single ZIP archive holding four tab separated
files and a readme with the official field definitions. Archives are written to
data/raw/ and left untouched: the raw layer is a faithful copy of the source,
and every later stage reads from it rather than from the network.

The script is idempotent. An archive that is already present is skipped, so a
re-run after an interrupted session fetches only what is missing.

Usage:
    python src/extract.py
"""

from __future__ import annotations

import logging
from pathlib import Path

from config import (
    DOWNLOAD_CHUNK_BYTES,
    QUARTERS,
    RAW_DIR,
    SEC_ZIP_URL_TEMPLATE,
)
from sec_client import sec_get

LOGGER = logging.getLogger("extract")


def download_quarter(quarter: str, destination_dir: Path) -> Path:
    """Download one quarterly archive into destination_dir and return its path.

    Returns immediately if the archive is already there. The transfer writes to
    a temporary name and renames only once the full expected size has arrived,
    so an interrupted download can never leave a truncated file that a later run
    would mistake for a complete one.

    A transfer that fails midway is retried by sec_client on the transient
    statuses. What that does not cover is a connection dropping mid body, after
    the response headers have already been accepted: the size check below is what
    catches that, and the retry then happens on the next run rather than in
    process, because the partial file is removed and nothing is left to skip.
    """
    target = destination_dir / f"{quarter}.zip"
    if target.exists():
        LOGGER.info(
            "%s already downloaded (%.1f MB), skipping",
            target.name,
            target.stat().st_size / 1e6,
        )
        return target

    url = SEC_ZIP_URL_TEMPLATE.format(quarter=quarter)
    partial = target.with_suffix(".zip.part")

    LOGGER.info("Downloading %s", url)
    with sec_get(url, stream=True) as response:
        expected_bytes = int(response.headers.get("Content-Length", 0))
        received_bytes = 0
        with partial.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=DOWNLOAD_CHUNK_BYTES):
                handle.write(chunk)
                received_bytes += len(chunk)

    if expected_bytes and received_bytes != expected_bytes:
        partial.unlink()
        raise OSError(
            f"{quarter}: incomplete download, expected {expected_bytes} bytes "
            f"but received {received_bytes}"
        )

    partial.replace(target)
    LOGGER.info("Saved %s (%.1f MB)", target.name, received_bytes / 1e6)
    return target


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    for quarter in QUARTERS:
        download_quarter(quarter, RAW_DIR)

    total_bytes = sum((RAW_DIR / f"{q}.zip").stat().st_size for q in QUARTERS)
    LOGGER.info("%d quarters in %s, %.1f MB total", len(QUARTERS), RAW_DIR, total_bytes / 1e6)


if __name__ == "__main__":
    main()
