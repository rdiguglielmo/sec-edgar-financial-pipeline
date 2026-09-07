"""Quality stage: persist the result of every dbt test as history.

dbt reports its test results to the terminal and then forgets them. The next run
overwrites the previous one, so the only answerable question is "did it pass
just now", never "when did this start failing" or "has this defect grown". This
stage reads what dbt actually ran and appends it to etl.dq_check_results, one
row per check per run.

The numbers are read, never typed
---------------------------------
Everything comes out of dbt/target/run_results.json, which dbt writes itself
after every invocation, joined to manifest.json for the check's severity, its
declared expectation and the model it covers. Nothing in this file knows how
many rows any check is supposed to return. A hand maintained copy of those
figures would drift from the tests within a session or two, and a quality table
that disagrees with the quality suite is worse than no table.

The expectation lives next to the test
--------------------------------------
Ten of the 156 checks are expected to fail, each on a documented property of
the source, and each declares its own count:

    config:
      meta:
        expected_failures: 138

A check without that key is expected to return nothing. So expected_failures is
declared in the same file as the test it belongs to, dbt carries it into the
manifest, and this stage compares it against what the check actually returned.
A documented failure that changes size stops being prose and becomes an alarm:
if the 138 duplicate keys ever become 139, the run says so. That is the
difference between a defect that is understood and one that is merely known
about.

The run therefore exits non zero when reality and the declaration disagree, in
either direction, and it writes the rows first. A run that found bad news still
has to record it.

Ordering
--------
run_results.json holds the results of the last dbt invocation of any kind, so
this stage refuses to read a file written by dbt run or dbt seed. Loading model
results into a table of check results would be silent nonsense.

Usage:
    dbt test --project-dir dbt --profiles-dir dbt
    python src/load_dq_results.py
"""

from __future__ import annotations

import json
import logging
from datetime import datetime

import duckdb

from config import (
    DBT_TARGET_DIR,
    DQ_RESULTS_TABLE,
    DUCKDB_PATH,
    ETL_SCHEMA,
)

LOGGER = logging.getLogger("load_dq_results")

# Seeds sit directly under seeds/ with no layer directory, so they are named
# rather than derived. Models are derived; see node_layer.
SEED_LAYER = "seed"


def read_artifacts() -> tuple[dict, dict]:
    """Return run_results.json and manifest.json, or explain what is missing."""
    run_results_path = DBT_TARGET_DIR / "run_results.json"
    manifest_path = DBT_TARGET_DIR / "manifest.json"

    for path in (run_results_path, manifest_path):
        if not path.exists():
            raise FileNotFoundError(
                f"{path} not found. Run dbt test --project-dir dbt --profiles-dir dbt "
                f"first; this stage records what that run produced."
            )

    run_results = json.loads(run_results_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    command = run_results.get("args", {}).get("which")
    if command != "test":
        raise RuntimeError(
            f"dbt/target/run_results.json was written by 'dbt {command}', not by "
            f"'dbt test'. Every dbt invocation overwrites that file, so loading this "
            f"one would record model results in a table of check results. Run "
            f"dbt test and then this stage."
        )

    return run_results, manifest


def node_layer(node: dict) -> str | None:
    """Return the layer a node sits in.

    Models are laid out one directory per layer, so dbt's fully qualified name
    carries it in second position: ['sec_edgar', 'staging', 'stg_num']. Reading
    it from there rather than from the model's name means a model renamed
    tomorrow still reports correctly. Seeds have no such directory and would
    otherwise report their own name as a layer.
    """
    if node["resource_type"] == "seed":
        return SEED_LAYER
    fqn = node.get("fqn") or []
    return fqn[1] if len(fqn) > 1 else None


def tested_relation(manifest: dict, test_node: dict) -> tuple[str | None, str | None]:
    """Return the relation a check covers and the layer it sits in.

    A generic test names its relation directly. A singular test reads whatever
    its SQL references, sometimes several: the duration check reads the fact and
    the account dimension. This takes the first, in the order dbt recorded the
    refs, which is the order they appear in the file and therefore the relation
    the check is written about. It is a label rather than an exhaustive list,
    and the seven singular tests are the only rows where the distinction exists.
    """
    attached = test_node.get("attached_node")
    if not attached:
        referenced = test_node.get("depends_on", {}).get("nodes", [])
        attached = referenced[0] if referenced else None
    if not attached:
        return None, None

    node = manifest["nodes"][attached]
    return node["name"], node_layer(node)


def check_rows(run_results: dict, manifest: dict, batch_id: str, run_at: datetime) -> list[tuple]:
    """Turn one dbt test invocation into rows for etl.dq_check_results."""
    rows = []
    for result in run_results["results"]:
        unique_id = result["unique_id"]
        node = manifest["nodes"].get(unique_id)
        if node is None:
            raise RuntimeError(
                f"{unique_id} is in run_results.json but not in manifest.json. The two "
                f"artefacts are from different invocations; re run dbt test."
            )

        test_metadata = node.get("test_metadata") or {}
        model_name, layer = tested_relation(manifest, node)
        expected = int((node["config"].get("meta") or {}).get("expected_failures", 0))

        rows.append(
            (
                node["name"],
                batch_id,
                run_at,
                # failures is null when a check errored rather than ran, which is
                # why status is stored beside it: zero rows failed and the check
                # never executed are different facts.
                result.get("failures"),
                expected,
                str(node["config"].get("severity", "error")).lower(),
                result["status"],
                layer,
                model_name,
                node.get("column_name"),
                test_metadata.get("name", "singular"),
                run_results["metadata"]["invocation_id"],
            )
        )
    return rows


def write_batch(connection: duckdb.DuckDBPyConnection, rows: list[tuple]) -> None:
    """Append one run's results, replacing that run if it was already loaded.

    Delete then insert inside one transaction, the same shape the raw loader and
    the incremental stage use. Loading the same artefact twice therefore leaves
    the history unchanged rather than doubling a run.
    """
    connection.execute(f'CREATE SCHEMA IF NOT EXISTS "{ETL_SCHEMA}"')
    connection.execute(
        f"""
        CREATE TABLE IF NOT EXISTS "{ETL_SCHEMA}"."{DQ_RESULTS_TABLE}" (
            check_name              VARCHAR NOT NULL,
            batch_id                VARCHAR NOT NULL,
            run_at                  TIMESTAMP NOT NULL,
            -- Rows the check returned. Null when the check errored instead of
            -- running. accepted_values returns offending values rather than
            -- rows, which is why some counts are small; the test's own comment
            -- says so where it matters.
            rows_failed             BIGINT,
            -- Declared beside the test in its own file. Zero unless the check is
            -- one of the ten documented failures.
            expected_rows_failed    BIGINT NOT NULL,
            severity                VARCHAR NOT NULL,
            status                  VARCHAR NOT NULL,
            layer                   VARCHAR,
            model_name              VARCHAR,
            column_name             VARCHAR,
            test_type               VARCHAR,
            -- dbt's own identifier for the run, so a row can be traced back to
            -- the artefact it came from.
            dbt_invocation_id       VARCHAR NOT NULL,
            PRIMARY KEY (batch_id, check_name)
        )
        """
    )

    batch_id = rows[0][1]
    connection.execute("BEGIN TRANSACTION")
    try:
        connection.execute(
            f'DELETE FROM "{ETL_SCHEMA}"."{DQ_RESULTS_TABLE}" WHERE batch_id = ?', [batch_id]
        )
        connection.executemany(
            f'INSERT INTO "{ETL_SCHEMA}"."{DQ_RESULTS_TABLE}" VALUES '
            f'({", ".join("?" * len(rows[0]))})',
            rows,
        )
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if not DUCKDB_PATH.exists():
        raise FileNotFoundError(f"No warehouse at {DUCKDB_PATH}.")

    run_results, manifest = read_artifacts()

    # The batch is stamped from when dbt started, not from now, so that the
    # identifier names the run being recorded rather than the moment it was
    # filed. Format matches _batch_id everywhere else in the pipeline.
    run_at = datetime.fromisoformat(
        run_results["metadata"]["invocation_started_at"].replace("Z", "+00:00")
    ).replace(tzinfo=None)
    batch_id = run_at.strftime("%Y%m%dT%H%M%SZ")

    rows = check_rows(run_results, manifest, batch_id, run_at)
    if not rows:
        raise RuntimeError("dbt test recorded no results. Nothing to load.")

    tests_in_project = sum(
        1 for node in manifest["nodes"].values() if node["resource_type"] == "test"
    )
    if len(rows) < tests_in_project:
        LOGGER.warning(
            "Batch covers %d of the %d checks in the project. A partial run makes a "
            "partial history: the checks not selected are absent from this batch, not "
            "passing in it.",
            len(rows),
            tests_in_project,
        )

    with duckdb.connect(DUCKDB_PATH) as connection:
        write_batch(connection, rows)
        total_batches = connection.execute(
            f'SELECT count(DISTINCT batch_id) FROM "{ETL_SCHEMA}"."{DQ_RESULTS_TABLE}"'
        ).fetchone()[0]

    passed = sum(1 for row in rows if row[6] == "pass")
    failed = sum(1 for row in rows if row[6] == "fail")
    other = len(rows) - passed - failed

    LOGGER.info(
        "Batch %s: %d checks, %d pass, %d fail%s. History now holds %d run%s.",
        batch_id,
        len(rows),
        passed,
        failed,
        f", {other} neither" if other else "",
        total_batches,
        "" if total_batches == 1 else "s",
    )

    unexpected = [row for row in rows if (row[3] or 0) != row[4]]
    if not unexpected:
        LOGGER.info(
            "Every check returned exactly what it declares, including the %d "
            "documented failures.",
            sum(1 for row in rows if row[4] > 0),
        )
        return

    for row in sorted(unexpected, key=lambda item: item[0]):
        LOGGER.error(
            "%s returned %s rows, declares %s. %s",
            row[0],
            row[3],
            row[4],
            "A documented failure changed size."
            if row[4] > 0
            else "A check that should return nothing did not.",
        )
    raise SystemExit(
        f"{len(unexpected)} check(s) disagree with the expectation declared beside them. "
        f"The batch was written first, so the history records this run. Either the data "
        f"changed and the declaration has to be updated with the reason, or something "
        f"broke."
    )


if __name__ == "__main__":
    main()
