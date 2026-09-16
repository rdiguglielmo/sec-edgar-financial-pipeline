# Pipeline internals

Where each stage reads from, what it writes, and where the result ends up. The
[README](../README.md) describes the pipeline as a sequence of steps; this page
covers the parts that are not visible from the outside — the bookkeeping schema,
what a dbt test does and does not leave behind, and why one stage has no SQL at
all.

Every file and line reference below is to this repository as it stands.

---

## Contents

_Each entry states its point; open one for the mechanics._

- [The stages, end to end](#the-stages-end-to-end)
- [The `etl` schema is built by Python, not by dbt](#the-etl-schema-is-built-by-python-not-by-dbt)
- [`etl.etl_watermark`: how far the incremental stage has read](#etletl_watermark-how-far-the-incremental-stage-has-read)
- [`etl.dq_check_results`, and why this stage has no SQL](#etldq_check_results-and-why-this-stage-has-no-sql)
- [What `dbt test` leaves behind](#what-dbt-test-leaves-behind)
- [Why `dbt build` is never used here](#why-dbt-build-is-never-used-here)
- [Re-exporting, and the diff that appears when nothing changed](#re-exporting-and-the-diff-that-appears-when-nothing-changed)

---

## The stages, end to end

<details open>
<summary><b>Eight commands, four schemas in one DuckDB file, and two of the eight write nothing
to the database at all.</b> The order is not arbitrary: three stages depend on an artefact the
previous one produced outside the warehouse.</summary>

| # | Command | Reads | Writes | Where the result lands |
|---|---|---|---|---|
| 1 | [`src/extract.py`](../src/extract.py) | SEC quarterly archive URLs | nothing in the database | `data/raw/{quarter}.zip` |
| 2 | [`src/load_raw.py`](../src/load_raw.py) | those ZIPs, streamed | `raw.sub`, `raw.tag`, `raw.pre`, `raw.num` | schema `raw` |
| 3 | [`src/incremental.py`](../src/incremental.py) | `data.sec.gov` submissions API, `raw.sub` | `raw.filing_index`, `etl.etl_watermark` | schemas `raw` and `etl` |
| 4 | `dbt seed` | `dbt/seeds/scope_companies.csv` | `marts.scope_companies` | schema `marts` |
| 5 | `dbt run` | schemas `raw` and `staging` | 5 staging models, 6 marts models | schemas `staging` and `marts` |
| 6 | `dbt test` | `staging` and `marts` | **nothing in the database** | `dbt/target/run_results.json` |
| 7 | [`src/load_dq_results.py`](../src/load_dq_results.py) | `dbt/target/run_results.json` and `manifest.json` | `etl.dq_check_results` | schema `etl` |
| 8 | [`src/export_marts.py`](../src/export_marts.py) | `marts.*`, `etl.dq_check_results` | nothing in the database | `output/parquet/*.parquet` |

Three ordering constraints are real rather than conventional:

- **Stage 3 needs stage 2.** The watermark is seeded from `max(accepted)` in
  `raw.sub`, so `incremental.py` raises rather than run against an empty
  warehouse.
- **Stage 5 needs stage 3,** because `stg_filing_index` reads
  `source('raw', 'filing_index')`, which stage 3 creates.
- **Stage 7 needs stage 6, and only stage 6.** Every dbt invocation overwrites
  `dbt/target/run_results.json`. Running `load_dq_results.py` after a `dbt run`
  would record model results in a table of check results, so the script inspects
  the artefact and refuses:

  ```python
  command = run_results.get("args", {}).get("which")
  if command != "test":
      raise RuntimeError(...)
  ```

Stages 6 and 7 both exit non-zero by design. That is the report, not a failure —
see [`engineering-notes.md`](engineering-notes.md).

A ninth script, [`src/profile_raw.py`](../src/profile_raw.py), sits outside the
sequence. It opens the warehouse read-only and prints the evidence behind
[`data_quality.md`](data_quality.md) to stdout, writing nothing anywhere, so
profiling can never be the reason a figure moved.

</details>

---

## The `etl` schema is built by Python, not by dbt

<details>
<summary><b>No dbt model, seed or test lands in <code>etl</code>: both of its tables are created
by DDL inside the Python stages that own them.</b> Bookkeeping is kept out of the data so that
rebuilding the raw layer does not take the record of what has been read and checked with
it.</summary>

Every dbt node in this project resolves to `staging` or `marts`, through the
schema override in
[`dbt/macros/generate_schema_name.sql`](../dbt/macros/generate_schema_name.sql).
Nothing in `dbt/` references `etl` at all. The schema is created idempotently by
whichever of the two Python stages runs first, both of them issuing
`CREATE SCHEMA IF NOT EXISTS "etl"`.

| Object | Created by | Written by | Read by |
|---|---|---|---|
| `etl.etl_watermark` | [`src/incremental.py`](../src/incremental.py), in `ensure_tables()` | `src/incremental.py` only, one upsert per company | `src/incremental.py` only, once per run |
| `etl.dq_check_results` | [`src/load_dq_results.py`](../src/load_dq_results.py), in `write_batch()` | `src/load_dq_results.py` only | `src/export_marts.py`, [`powerbi/verification-gates.sql`](../powerbi/verification-gates.sql) |

The split is deliberate in both directions. These two tables record *what the
pipeline did*, not what the companies reported, so they do not belong in a layer
that `--full-refresh` is expected to rebuild from the source. And because they
are written by exactly one script each, there is no question of which stage owns
a row.

One table that could plausibly live here does not. `raw.filing_index` is also
written by `incremental.py`, but it holds filing metadata retrieved from the SEC,
which is source data. It stays in `raw`.

Column-level documentation for both tables is in
[`data_dictionary.md`](data_dictionary.md). This page covers where they come from.

</details>

---

## `etl.etl_watermark`: how far the incremental stage has read

<details>
<summary><b>One row per company rather than one for the source, because each company is a
separate HTTP request.</b> A shared watermark advanced past a company whose request failed would
skip that company's filings permanently, and nothing would report it.</summary>

The bulk archives run roughly a quarter behind what companies have actually
filed. `incremental.py` closes that gap by asking the submissions API what each
scope company has filed since the last run, which requires remembering where the
last run stopped.

### The table

Created in `ensure_tables()`, with the reasoning in the DDL itself:

```sql
CREATE TABLE IF NOT EXISTS "etl"."etl_watermark" (
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
```

Ten rows, one per company in the scope. A row looks like this:

| Column | Example |
|---|---|
| `source_name` | `submissions/CIK0000063908` |
| `last_accepted_at` | `2026-08-04 11:44:19` |
| `filings_loaded_last_run` | `3` |
| `updated_at` | `2026-08-04 11:44:31` |
| `batch_id` | `20260804T114419Z` |

`source_name` is the endpoint, built as `f"submissions/CIK{cik}"` with the cik
already padded to ten digits — the API returns 404 for the unpadded form, which
is the shape the archives ship it in.

### Where the first value comes from

An empty table is the normal state on a fresh clone, so the run resolves a
starting point in three steps:

```python
watermark = stored.get(source_name) or seed_watermark(connection, cik)
if watermark is None:
    watermark = datetime.min
```

1. **A stored row exists** — use it.
2. **No stored row** — derive one from the bulk load. `seed_watermark()` takes
   `max(accepted)` from `raw.sub` for that company and subtracts a safety margin:

   ```python
   eastern = datetime.strptime(str(row[0])[:19], "%Y-%m-%d %H:%M:%S").replace(
       tzinfo=ZoneInfo(SEC_SOURCE_TIMEZONE)
   )
   as_utc = eastern.astimezone(timezone.utc).replace(tzinfo=None)
   return as_utc - timedelta(seconds=WATERMARK_SAFETY_MARGIN_SECONDS)
   ```

   **The margin exists because the two sources record the same event
   differently.** `sub.txt` stores acceptance in US Eastern rounded to the
   minute; the API reports it in UTC to the second. Rounding can put the recorded
   value up to 30 seconds ahead of the true one, and a watermark that is ahead of
   reality skips filings. `WATERMARK_SAFETY_MARGIN_SECONDS` is 60, so the
   boundary always errs towards **re-reading** a filing rather than missing one —
   which costs nothing, because the write is an upsert on the natural key.
3. **No bulk history at all** — `datetime.min`, so the whole index is loaded.
   Only reachable for a company added to the scope after the archives were
   loaded.

### How it moves

Selection is strictly greater than the watermark:

```python
selected = [row for row in rows
            if _parse_api_timestamp(row["acceptance_datetime"]) > watermark]
```

and the new value is the highest acceptance timestamp among the rows actually
written, defaulting to the incoming watermark when nothing was selected. The
write is a single upsert:

```sql
INSERT INTO "etl"."etl_watermark"
    (source_name, last_accepted_at, filings_loaded_last_run, updated_at, batch_id)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT (source_name) DO UPDATE SET
    last_accepted_at        = excluded.last_accepted_at,
    filings_loaded_last_run = excluded.filings_loaded_last_run,
    updated_at              = excluded.updated_at,
    batch_id                = excluded.batch_id
```

**It sits inside the same transaction as the write to `raw.filing_index`.** That
is the part worth copying. A run interrupted between inserting the rows and
moving the watermark would leave a watermark claiming rows that are not there,
and the next run would start after them — a gap that no later run ever notices,
because the watermark says the work was done. One transaction makes the two
facts inseparable.

### Proving the write is idempotent rather than the filter

`incremental.py --replay` does not delete the watermark. It ignores it,
substituting an empty dict so every company falls through to the seed path and
the same window is fetched and written a second time. Row counts must come back
identical.

The distinction matters: a run that writes nothing because its filter excluded
everything proves nothing about the write. `--replay` deliberately removes the
filter, so what is being tested is the upsert and the
`PRIMARY KEY (cik, accession_number)` behind it.

</details>

---

## `etl.dq_check_results`, and why this stage has no SQL

<details>
<summary><b>This is the one stage whose input is not the warehouse, which is why there is no
<code>.sql</code> file behind it.</b> It reads dbt's own JSON run artefacts, so there is nothing
for SQL to select from — and nothing in the database to select from either, because dbt does
not persist test results here.</summary>

dbt overwrites its own results on every invocation, so "did the suite pass" is
knowable only for the run that just finished. This stage turns that into a
history.

### Why no query

Three reasons, and the first one is sufficient:

1. **The input is `dbt/target/run_results.json` and `dbt/target/manifest.json`,
   two JSON files outside the database.** SQL cannot read the metadata of the dbt
   invocation that produced it: the check name, its status, its failure count,
   the invocation id and the start timestamp exist only in those artefacts.
2. **There is nothing in the database to query anyway.** dbt materialises no
   test results in this project; see the next section.
3. **The expectation lives in the dbt graph, not in the data.**
   `meta.expected_failures` is declared beside each test in YAML or in the test
   file, and is read out of `manifest.json`. A SQL query against the warehouse
   has no access to it.

So the DDL for this table exists only in Python, in `write_batch()`. It is the
one object in the warehouse with no `.sql` file anywhere in the repository, and
that is a property of what it records rather than an oversight.

### What it writes

156 rows per run — one per check — keyed on `PRIMARY KEY (batch_id, check_name)`,
with `batch_id` stamped from **dbt's own start time** rather than from now, so a
row can be traced back to the invocation that produced it. The write is a delete
then insert inside one transaction:

```sql
DELETE FROM "etl"."dq_check_results" WHERE batch_id = ?;
INSERT INTO "etl"."dq_check_results" VALUES (?, ?, ..., ?);
```

Loading the same artefact twice is therefore a no-op on the history rather than a
doubled run.

### The order of the two halves is deliberate

The batch is written **first**, and only then compared against what each check
declared:

```python
unexpected = [row for row in rows if (row[3] or 0) != row[4]]
```

`row[3]` is what the check returned, `row[4]` what it declared. A run that found
bad news still records it before failing, so the history contains the evidence for
the failure rather than stopping short of it.

The comparison is **exact and bidirectional**. A documented failure that shrinks
fails the load just as loudly as one that grows, because both mean the source
moved under a number this repository publishes. On disagreement the script exits
non-zero with one logged line per offending check.

</details>

---

## What `dbt test` leaves behind

<details>
<summary><b>Nothing in the database. Not one of the 156 checks creates or populates an
object.</b> The offending rows are not retained anywhere, so <code>rows_failed</code> is a count
and re-running the test is the only way to see what failed.</summary>

The seven singular tests in [`dbt/tests/`](../dbt/tests) look like models — they
are `.sql` files that `select` rows. They are not models, and the difference is
worth being explicit about.

### What dbt does with them

A dbt test is a query that is expected to return nothing. At run time dbt wraps
each one:

```sql
select count(*) as failures
from (
    -- the contents of the test file
) dbt_internal_test
```

and reads the scalar back. Pure `SELECT`: no DDL, no DML, nothing added to the
catalogue.

dbt *can* persist failing rows, through `store_failures`, which materialises them
into a `dbt_test__audit` schema. **It is not configured anywhere in this
repository** — not in `dbt_project.yml`, not in `profiles.yml`, not in either
`schema.yml`, not in any test file — so it resolves to null for all 156 checks
and no such schema is ever created.

### Where the result goes

| Destination | Persisted? |
|---|---|
| `dbt/target/run_results.json` | Yes — status and failure count per check. The authoritative record |
| Terminal output and `dbt/logs/dbt.log` | Yes, on disk, human-readable only |
| `dbt/target/compiled/` | Yes — the rendered SQL text, not the results |
| A database table | **No**, for any of the 156 |
| `etl.dq_check_results` | Only after `src/load_dq_results.py` runs, as a separate stage |

`dbt/target/` is gitignored, which is why the quality history exists on whichever
machine ran the tests, and why the exported
[`output/parquet/dq_check_results.parquet`](../output/parquet/dq_check_results.parquet)
is committed: it is the only form of that history a reader who clones the
repository gets without running anything.

### The consequence

`rows_failed` in `etl.dq_check_results` is a **count**. The rows that produced it
are not stored, and the only way to see them is to run the test's query again —
which the test files support, because each is a plain `select` that can be run
directly against the warehouse with [`src/query.py`](../src/query.py).

The seven singular tests, and what each asserts:

| Test | Assertion |
|---|---|
| `assert_fact_does_not_fan_out_over_dimensions` | The fact joined to all five dimensions returns the fact's own row count, not a multiple of it |
| `assert_fact_keeps_every_scope_row` | The fact holds exactly the `stg_num` rows whose filing is in `dim_filing` — none added, none lost |
| `assert_scope_roster_is_complete` | Every seed row reaches `dim_company` and back, with one `10-K` and three `10-Q` per company |
| `assert_fact_duration_matches_concept_period_type` | No fact contradicts the period type its concept declares. Declares 33 |
| `assert_fact_period_end_within_plausible_range` | No period end date outside 2010 to 2027. Declares 561 |
| `assert_one_company_name_per_cik` | No cik carries more than one company name in `stg_sub`. Declares 172 |
| `assert_filing_period_end_not_after_filed_date` | No filing has a period ending after it was filed. Declares 2 |

The first three are expected to return nothing. The four that declare a count are
among the ten documented failures; the other six are declared in YAML beside the
column they test.

</details>

---

## Why `dbt build` is never used here

<details>
<summary><b><code>dbt build</code> treats every test as a gate on the models downstream of it,
which is the right default and the wrong one for this project.</b> Ten checks fail deliberately
at <code>error</code> severity, so a build stops in staging and never reaches the marts.</summary>

`dbt build` runs seeds, models, snapshots and tests in a single pass, in
dependency order, testing each node as soon as it is built. A model whose upstream
test failed is skipped, along with everything downstream of it.

That behaviour exists for a good reason: in most projects a failing test means the
data is wrong, and building on top of wrong data compounds the error. `build` is
the correct default there, and a CI pipeline that must stop on any failure is
exactly what it is for.

**It is the wrong default here because ten of the 156 checks are expected to
fail.** They are documented properties of the source — a key the SEC declares
unique and is not, 655,031 unpopulated values, an undocumented statement code —
and each declares the number it should return. Under `build`, the first of them
that runs stops the marts from being built at all.

There are two ways out, and only one is acceptable:

- Soften the ten to `severity: warn` so `build` proceeds. This makes the pipeline
  green by lowering the bar, and a warning is something nobody reads. All 156
  checks in this project run at `error`.
- **Separate building from testing.** `dbt seed` and `dbt run` build the
  warehouse; `dbt test` then measures it, and `load_dq_results.py` records what it
  measured. Each stage reports on its own terms, and a failing check is
  information rather than an obstacle.

The Makefile takes the second route, and marks the point where it matters:

```make
all: extract load incremental dbt
	-$(DBT) test --project-dir dbt --profiles-dir dbt
	$(PYTHON) src/load_dq_results.py
	$(PYTHON) src/export_marts.py
```

The leading `-` on `dbt test` is load-bearing. Without it `make` aborts on the
expected non-zero exit and skips the two stages that record and export the very
results that make the suite worth running.

**When `dbt build` is the right command:** a project where every test passing is
the invariant, where a failure means stop, and where nothing is a documented
exception. That is most projects. This one deliberately is not.

</details>

---

## Re-exporting, and the diff that appears when nothing changed

<details>
<summary><b>Rebuilding the pipeline produces a 1.8 MB binary diff even when no figure
moved.</b> <code>_ingested_at</code> and <code>_batch_id</code> change on every load, and
<code>_ingested_at</code> is what the incremental models select on, so neither can be dropped to
make the diff go away.</summary>

[`src/export_marts.py`](../src/export_marts.py) copies the marts and the quality
history to `output/parquet/`, which is committed so the repository can be read
without building anything. Two properties of that export are deliberate:

- **Every relation is written `ORDER BY` its key,** so identical data produces
  identical bytes. Without it three of the six files reshuffled between runs and
  produced a diff on every export.
- **Row counts are verified by reading each file back,** and each is checked
  against GitHub's 100 MiB hard limit before it can become a rejected push.

What ordering cannot remove is the ingestion metadata.
[`fct_financial_facts.parquet`](../output/parquet/fct_financial_facts.parquet)
carries `_ingested_at` and `_batch_id` on every row, both of which change when the
raw layer is reloaded even if every reported figure is identical. `_ingested_at`
is the column `stg_num` selects on to find its incremental batch — it is what
catches the SEC republishing a corrected archive under an unchanged file name — so
it cannot be dropped from the fact to keep the diff clean.

**Re-export only when the data moved.** A rebuild for its own sake writes 1.8 MB
of binary churn into the history that says nothing about the data.

</details>
