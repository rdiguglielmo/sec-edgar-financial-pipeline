# Engineering Notes

Working notes for this repository. Read [`README.md`](../README.md) for what the project is and how to run it,
and [`pipeline.md`](pipeline.md) for how the stages fit together; this file is only the rules
that are easy to break and expensive to break.

## The trap that produces a wrong number without anything failing

**No measure or query may aggregate without taking an explicit position on
`is_year_to_date`, `is_consolidated` and `is_latest_report`, and without filtering
`unit_of_measure`.** One that does not is wrong by close to a factor of two:

| Flag | What it inflates if ignored |
|---|---|
| `is_year_to_date` | Year-to-date rows sit alongside the quarters they contain. `period_length_qtrs` has 88 distinct values, not three |
| `is_consolidated` | Segment breakdowns repeat the company total. This is the majority of rows, not an edge case: 57.76% |
| `is_latest_report` | Figures superseded by a later filing: 1,840 of 22,604 |

Also: 134 distinct units coexist in the fact table, so `unit_of_measure` is always filtered;
Q4 is derived and must be shown as such; and the three negative equity values must not surface
as low ratios.

**There is no single tag meaning "revenue", and none meaning the bottom line.** Four revenue
tags are in use and 350 companies use more than one. Any such metric must `coalesce` over the
accepted tags and **make visible which one it used**. Within the ten-company scope,
`NetIncomeLoss` reaches 8 of 10 companies and `Revenues` only 6 — which is why the dashboard
leads on operating income instead.

Full detail: [`docs/data_dictionary.md`](data_dictionary.md), [`docs/modeling_decisions.md`](modeling_decisions.md), [`docs/data_quality.md`](data_quality.md).

## Running the pipeline

Order: `extract -> load -> incremental -> dbt -> test -> dq -> export`. Three things that are
not obvious:

- **dbt runs from the repository root**, always with `--project-dir dbt --profiles-dir dbt`.
  From anywhere else, dbt-duckdb silently creates an empty database at that relative path and
  everything fails with "source not found".
- **Never `dbt build`.** It interleaves models and tests and skips everything downstream of a
  failing test — and ten of these tests fail deliberately, so `build` never reaches the marts.
  Use `seed` + `run`, then `test` separately. The full argument, and when `build` *is* the right
  command, is in [`pipeline.md`](pipeline.md).
- **[`src/load_dq_results.py`](../src/load_dq_results.py) runs only after `dbt test`**, never after `dbt run`. Every dbt
  invocation overwrites `dbt/target/run_results.json`.

`dbt test` and [`load_dq_results.py`](../src/load_dq_results.py) exit non-zero **by design**. That
is the report, not a failure.

## The ten failing checks are a feature

156 quality checks, 146 pass, 10 fail on purpose. Each declares its expected row count in
`meta.expected_failures`, and [`load_dq_results.py`](../src/load_dq_results.py) compares declared against actual and fails
if they diverge. **Do not weaken one to make it pass.** If one of these numbers moves, the
pipeline is telling you something.

## Power BI

The report itself is not published here. What is in `powerbi/` is the part that stands on its
own: the three page screenshots, and [`verification-gates.sql`](../powerbi/verification-gates.sql) — the queries every figure on
those pages was checked against before it shipped.

Left out are the PBIP project (the semantic model and the generated visual JSON) and
`theme-lab/`, a token-based theme compiler with an automated contrast audit. Neither is
interesting to read as JSON, and the theme system is a general-purpose tool rather than a part
of this pipeline, so it belongs in its own repository rather than buried in this one. The
README summarises what both do and what building them taught.

The measures behind the dashboard obey the aggregation rule at the top of this file, which is
where a report over this fact table goes wrong if it goes wrong at all.

**Every figure on those pages has its expected value written down before the query runs**, in
[`verification-gates.sql`](../powerbi/verification-gates.sql). If a result disagrees with the
expectation, the report is wrong — the expectation does not get adjusted to fit. That ordering
is the whole mechanism, and it costs nothing.

## Re-exporting

Rebuilding the pipeline produces a 1.8 MB binary diff even when no figure moved, because
`_ingested_at` and `_batch_id` change on every load and `_ingested_at` is the incremental
selector, so it cannot be dropped. **Re-export only when the data moved.** Detail in
[`pipeline.md`](pipeline.md).
