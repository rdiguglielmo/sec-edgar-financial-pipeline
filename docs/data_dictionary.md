# Data dictionary

Every table and column an analyst or a report reads: the six marts models, which
are exported to `output/parquet/`, and the two bookkeeping tables in the `etl`
schema.

The staging layer is not repeated here. It is a typed and renamed projection of
the four source files, documented column by column with its tests in
[`../dbt/models/staging/schema.yml`](../dbt/models/staging/schema.yml); the
mapping from the SEC's own column names is at the end of this document.

Types are DuckDB types and carry through to Parquet unchanged. Row counts are as
built from the 2025Q1 to 2025Q4 archives.

---

## Contents

- [Read this before summing anything](#read-this-before-summing-anything)
- [marts.dim_company](#martsdim_company)
- [marts.dim_filing](#martsdim_filing)
- [marts.dim_account](#martsdim_account)
- [marts.dim_statement](#martsdim_statement)
- [marts.dim_date](#martsdim_date)
- [marts.fct_financial_facts](#martsfct_financial_facts)
- [etl.etl_watermark](#etletl_watermark)
- [etl.dq_check_results](#etldq_check_results)
- [Source columns and what they became](#source-columns-and-what-they-became)

---

## Read this before summing anything

Three properties of this source produce a total larger than the truth **without
raising an error**, and the fact table carries a flag for each rather than
filtering the rows away. Filtering was measured and rejected in every case; see
[`modeling_decisions.md`](modeling_decisions.md).

| Flag | True on | What is double counted if it is ignored |
|---|---|---|
| `is_year_to_date` | 5,135 of 22,604 | The half year and nine month figures contain the individual quarters filed beside them |
| `is_consolidated` | false on 11,362 of 22,604 | Segment breakdowns sit beside the company total they decompose |
| `is_latest_report` | false on 1,840 of 22,604 | A `10-Q` repeats the prior year comparative, so the same economic fact is reported by several filings |

A measure that sums `value` and takes no position on all three is wrong by
roughly a factor of two. The queries in `../analysis/` each open by declaring
which of the three they apply and why, and are the worked examples.

Two further rules apply to any aggregate:

- **Filter `unit_of_measure`.** The scope holds USD on 21,438 facts and shares
  on 1,166. Adding a dollar to a share is arithmetic on incompatible quantities.
- **Filter `period_length_qtrs` to one duration.** A quarter and a full year in
  the same sum is the same hazard as `is_year_to_date` in a different shape.

---

## marts.dim_company

One row per company in the analytical scope. **10 rows**, of the 7,151 companies
that filed in 2025. Type 1: every attribute holds the last known value, taken
from the company's most recently filed filing.

| Column | Type | Description |
|---|---|---|
| `company_key` | varchar | Primary key. md5 of `cik`. |
| `cik` | varchar | SEC company identifier, **ten digits, zero padded**. The source ships it unpadded; the submissions API rejects the unpadded form. Also the join to the scope seed. |
| `company_name` | varchar | Name as filed on the most recent filing. Source spelling, upper case and abbreviated: `MCDONALDS CORP`, not a display name. |
| `former_company_name` | varchar | Previous name carried on the filing. Null for all ten. |
| `name_changed_date` | date | Date the former name changed. Null wherever `former_company_name` is. |
| `has_changed_name` | boolean | True when the company filed under more than one name. False for all ten; 2.41% across the whole data set, which is the measurement behind the type 1 decision. |
| `sic_code` | varchar | Self declared industry code, `5810` or `5812`. Not validated by anyone. |
| `industry_name` | varchar | Label for the code, written in the model. The archives ship no SIC lookup table. |
| `business_city` | varchar | City of the business address. |
| `business_state` | varchar | Two letter state of the business address. |
| `business_country` | varchar | Country of the business address. |
| `incorporation_state` | varchar | State of incorporation, frequently not where the company operates. |
| `incorporation_country` | varchar | Country of incorporation. |
| `ein` | varchar | Employer identification number as filed. |
| `fiscal_year_end_mmdd` | varchar | Fiscal year end as `mmdd`, **text so that `0630` does not become `630`**. `1231` for all ten, which is scope criterion 3. |
| `filer_status` | varchar | SEC filer category by size. `1-LAF`, large accelerated, for all ten. |

---

## marts.dim_filing

One row per filing made by a scope company. **40 rows**: ten `10-K` and thirty
`10-Q`, of the 26,085 filings in the archives. The only filter is the company;
that all forty are periodic, detailed, unamended and single registrant is a
measured property of the scope, asserted by tests rather than imposed by a
`where` clause.

| Column | Type | Description |
|---|---|---|
| `filing_key` | varchar | Primary key. md5 of `accession_number`. |
| `accession_number` | varchar | SEC accession number, unique per filing. Source column `adsh`. |
| `cik` | varchar | Company that filed, as the natural identifier. Not a foreign key to `dim_company`: a dimension pointing at another dimension is a snowflake, and the fact already carries both keys. |
| `form_type` | varchar | `10-K` or `10-Q`. |
| `is_amendment` | boolean | True when the form type ends in `/A`. False for all forty; 4.57% of all 2025 filings are amendments. |
| `fiscal_year` | integer | Fiscal year as declared by the filer. |
| `fiscal_period` | varchar | `Q1`, `Q2`, `Q3` or `FY`. Never empty here, against 5.37% of all filings. |
| `period_end_date` | date | Balance sheet date **of the filing**, not of a fact inside it. |
| `filed_date` | date | Date EDGAR assigned. 2025-02-05 to 2025-11-10. |
| `accepted_at` | timestamp | When EDGAR accepted the submission, US Eastern, **rounded to the minute**. It precedes `filed_date` on 7.88% of all filings, because a submission after the daily cutoff is dated the next business day. No test asserts an ordering, for that reason. |
| `is_detailed` | boolean | False when only statement level figures were tagged. True for all forty. |
| `is_previous_report` | boolean | The source's `prevrpt` flag. Unusable as a restatement signal: set on 5 filings out of 26,085. Use `fct_financial_facts.is_restated`. |
| `registrant_count` | integer | Number of registrants. 1 for all forty. |
| `is_multi_registrant` | boolean | True when several registrants filed jointly. False for all forty; 495 filings across the data set carry more than one. |

---

## marts.dim_account

One row per accounting concept the scope reports. **1,066 rows**, of 329,861 in
the catalogue. Conformed to the fact: every row is referenced by at least one
fact.

**The grain is `(tag_name, tag_version)`, not the concept name.** 1,066 rows
cover 379 standard names and 114 custom ones, because the same standard element
exists under two taxonomy years and a custom concept counts once per filing that
invented it. Any count of concepts has to say which of the two it means, which is
why `tag_name` is exposed as a column.

| Column | Type | Description |
|---|---|---|
| `account_key` | varchar | Primary key. md5 of tag name and version. |
| `tag_name` | varchar | XBRL element name. **Not unique in this dimension**; see the grain note above. |
| `tag_version` | varchar | Taxonomy namespace for a standard concept; **the filing's own accession number** for a company specific one. |
| `is_custom_tag` | boolean | True for a company specific concept. 340 of 1,066 rows, carrying 1,337 of 22,604 facts. |
| `tag_label` | varchar | Human readable label. Present on all 1,066; two concepts in the full catalogue have none. |
| `tag_documentation` | varchar | Definition text. Present on all 1,066, against 10.80% missing across the catalogue. |
| `data_type` | varchar | `monetary`, `shares`, `perShare`, `pure` and the rest. |
| `period_type` | varchar | `I` for a value at a point in time, `D` for a value over a period. Contradicted by the reported facts on 33 rows; see the singular test. |
| `balance_type` | varchar | `D` debit, `C` credit, null on 94 concepts that have neither. It is what says whether a negative value is an error or a contra account behaving normally. |
| `is_abstract` | boolean | False on every concept in the source. Kept for fidelity; carries no information. |

---

## marts.dim_statement

One row per financial statement code. **8 rows**, read from the distinct codes
present in the source rather than typed in.

The one dimension **not** conformed to the fact: scope facts reference five
codes. `SI`, `UN` and the undocumented empty string are kept because this is a
code list, and because dropping the empty one would delete a finding.

| Column | Type | Description |
|---|---|---|
| `statement_key` | varchar | Primary key. md5 of the statement code. |
| `statement_code` | varchar | `BS`, `IS`, `CF`, `EQ`, `CI`, `SI`, `UN`, and an eighth value **the SEC does not document: the empty string**, on 257 presentation lines across 8 filings. |
| `statement_name` | varchar | Readable name, written in the model. |
| `display_order` | integer | Reading order for reports: income statement, balance sheet, cash flow, equity, comprehensive income, then the two the project does not use, then the undocumented code. |
| `is_documented` | boolean | False only for the empty code. The column exists so a report can exclude it without hard coding an empty string. |

---

## marts.dim_date

One row per calendar day, 2016-01-01 to 2025-12-31. **3,653 rows**, generated
rather than read.

**No fiscal columns.** All ten companies close in December, so calendar and
fiscal periods are the same thing, and a `fiscal_year` identical to
`calendar_year` would become false the day the scope admits a company that closes
in June. The assumption is asserted instead: a test requires
`dim_company.fiscal_year_end_mmdd` to be `1231` for all ten.

The bounds are **derived** from the dates the scope actually uses and rounded
outward to whole years, not typed in. Hard coded bounds would work today and
break silently on the first archive carrying an older comparative.

| Column | Type | Description |
|---|---|---|
| `date_key` | date | Primary key, the date itself. Facts join on it directly; no surrogate integer. |
| `calendar_year` | bigint | |
| `calendar_quarter` | bigint | 1 to 4. |
| `calendar_month` | bigint | 1 to 12. |
| `month_name` | varchar | |
| `day_of_month` | bigint | |
| `quarter_label` | varchar | Year and quarter as one string, `2025 Q3`, for chart axes. |
| `is_month_end` | boolean | |
| `is_quarter_end` | boolean | True on 31 March, 30 June, 30 September and 31 December. |
| `is_year_end` | boolean | |

---

## marts.fct_financial_facts

One row per numeric fact reported by a scope company. **22,604 rows**, of
14,619,494 in the staging layer.

Grain: the eight fields the SEC declares unique for `num.txt`, which are the
filing, the concept, its version, the period end, the duration, the unit, the
segment breakdown and the co-registrant. The only filter applied at this layer is
the company.

| Column | Type | Description |
|---|---|---|
| `fact_key` | varchar | Primary key. md5 of the eight fields above. Unique on all 22,604 here; the same test fails at staging on 138 keys, all belonging to one filer outside the scope. |
| `economic_fact_key` | varchar | **The same fact across filings**: the natural key with the filing replaced by the company. 22,604 rows carry 20,764 distinct values. |
| `company_key` | varchar | FK to `dim_company`. |
| `filing_key` | varchar | FK to `dim_filing`. |
| `account_key` | varchar | FK to `dim_account`. |
| `statement_key` | varchar | FK to `dim_statement`. The statement the fact was presented on, resolved to exactly one line by the rule in the model. Never null: a null would mean the join missed. |
| `period_end_key` | date | FK to `dim_date`. End of the period the fact covers, **not** the date it was filed. |
| `period_length_qtrs` | integer | Quarters the fact spans: `0` a point in time, `1` a quarter, `2` a half year, `3` nine months, `4` a full year. In the scope: 5,604 / 7,572 / 2,558 / 2,577 / 4,293. Values above 4 were dropped in staging as filer error. |
| `is_year_to_date` | boolean | **Double counting flag.** True for the half year and nine month durations, 5,135 facts, which contain the quarters filed beside them. |
| `unit_of_measure` | varchar | `USD` on 21,438 facts, `shares` on 1,166. Every measure must filter on this. |
| `segments` | varchar | XBRL axis and member the fact is broken down by. **Empty string, never null, for the company level figure**: empty means consolidated, which is a value rather than an absence. |
| `is_consolidated` | boolean | **Double counting flag.** True for the company level figure, false for one of its breakdowns. 11,242 of 22,604 are consolidated. |
| `coregistrant` | varchar | Subsidiary the fact is attributed to. Empty on all 22,604 in the scope. |
| `value` | decimal(28,4) | The reported figure. **Null on 67 facts**, 0.30% of the scope against 4.48% of the source, and kept rather than filtered. |
| `footnote` | varchar | Filer's note on the fact. Present on 93 facts. |
| `has_footnote` | boolean | True on 93 facts, 0.41%. |
| `has_duplicate_natural_key` | boolean | False on all 22,604. Carried so that a scope later including the affected filer inherits the warning rather than the surprise. |
| `has_multiple_statement_lines` | boolean | True on 3,368 facts, 14.9%, whose concept appears on more than one presentation line of the same filing. The model picked one; this says it had to choose. |
| `spans_multiple_statements` | boolean | True on 2,938 facts, 13.0%, whose presentation lines fall on more than one statement. Depreciation, which belongs to both the income statement and the cash flow statement, is the ordinary case. |
| `presentation_line_number` | integer | Line number of the chosen presentation line. Degenerate attribute. |
| `presentation_label` | varchar | Label the filer wrote for that line, which is how the figure reads on the published statement rather than how the taxonomy names it. |
| `is_latest_report` | boolean | **Double counting flag.** True on the most recently filed version of an economic fact, 20,764 of 22,604. |
| `is_restated` | boolean | True when an earlier filing reported a different value for the same economic fact. Two facts in the scope, both goodwill, both revised down. |
| `_ingested_at` | timestamp | When the row's source archive was loaded. |
| `_batch_id` | varchar | Load batch that produced it. |

---

## etl.etl_watermark

How far the incremental stage has read. **10 rows, one per company**, not one for
the source: each company is a separate HTTP request, and a shared watermark
advanced past a company whose request failed would skip that company's filings
permanently.

| Column | Type | Description |
|---|---|---|
| `source_name` | varchar | Primary key. The endpoint read, which here is one per company. |
| `last_accepted_at` | timestamp | Latest acceptance timestamp written, naive UTC. The next run selects strictly after this. Seeded from the bulk load **minus 60 seconds**, because the two sources round the same event differently and the margin must fail towards re-reading. |
| `filings_loaded_last_run` | bigint | Rows written by the run that last touched this source. Not a running total: a run that finds nothing records zero. |
| `updated_at` | timestamp | When the watermark last moved. |
| `batch_id` | varchar | Run that moved it. |

---

## etl.dq_check_results

One row per data quality check per run, appended rather than overwritten.
**156 rows per run.** Populated by `src/load_dq_results.py` from dbt's own
`run_results.json`; nothing in it is typed in by hand.

| Column | Type | Description |
|---|---|---|
| `check_name` | varchar | The dbt test name. Part of the primary key. |
| `batch_id` | varchar | Run identifier, stamped from when dbt started, same format as `_batch_id` elsewhere. Part of the primary key. |
| `run_at` | timestamp | When the dbt invocation started, naive UTC. |
| `rows_failed` | bigint | Rows the check returned. **Null when the check errored rather than ran.** `accepted_values` returns offending values rather than rows, which is why some counts are small. |
| `expected_rows_failed` | bigint | What the check declares it should return, read from `meta.expected_failures` beside the test itself. Zero unless the check is one of the ten documented failures. A disagreement with `rows_failed` fails the load. |
| `severity` | varchar | `error` or `warn`. All 156 are `error`: none was softened to let a build pass. |
| `status` | varchar | `pass`, `fail`, `error` or `skipped`. Stored beside `rows_failed` because zero rows failed and the check never executing are different facts. |
| `layer` | varchar | `staging`, `marts` or `seed`, read from the model's position in the dbt graph rather than from its name. |
| `model_name` | varchar | The relation the check covers. For a singular test that reads several, the first one its SQL references. |
| `column_name` | varchar | Column tested. Null for singular tests. |
| `test_type` | varchar | `not_null`, `unique`, `accepted_values`, `relationships`, or `singular`. |
| `dbt_invocation_id` | varchar | dbt's own identifier for the run, so a row can be traced back to the artefact it came from. |

---

## Source columns and what they became

The SEC's column names date from the 1990s and are not readable without the
dictionary open beside them. Staging renames them once; everything downstream
uses the readable name. This is the mapping for the two files that matter most.

### sub.txt, one row per filing

| Source | Staging | Note |
|---|---|---|
| `adsh` | `accession_number` | |
| `cik` | `cik` | **Left padded to ten digits.** The source ships it unpadded. |
| `name` | `company_name` | |
| `sic` | `sic_code` | |
| `fye` | `fiscal_year_end_mmdd` | Kept as text; the padding is significant. |
| `form` | `form_type` | |
| `period` | `period_end_date` | |
| `fy` | `fiscal_year` | |
| `fp` | `fiscal_period` | |
| `filed` | `filed_date` | |
| `accepted` | `accepted_at` | US Eastern, rounded to the minute. |
| `prevrpt` | `is_previous_report` | |
| `detail` | `is_detailed` | |
| `nciks` | `registrant_count` | |
| `aciks` | `additional_ciks` | |
| `afs` | `filer_status` | |
| `wksi` | `is_well_known_seasoned_issuer` | |
| `former`, `changed` | `former_company_name`, `name_changed_date` | |
| `cityba`, `stprba`, `countryba` | `business_city`, `business_state`, `business_country` | |
| `stprinc`, `countryinc` | `incorporation_state`, `incorporation_country` | |

### num.txt, one row per reported figure

| Source | Staging | Note |
|---|---|---|
| `adsh` | `accession_number` | |
| `tag` | `tag_name` | |
| `version` | `tag_version` | Holds `adsh` for a company specific concept. |
| `ddate` | `period_end_date` | |
| `qtrs` | `period_length_qtrs` | 88 distinct values in the source, not the three the documentation implies. |
| `uom` | `unit_of_measure` | |
| `segments` | `segments` | Empty means consolidated. Preserved as empty, never nulled. |
| `coreg` | `coregistrant` | |
| `value` | `value` | Empty becomes null here; empty and null mean different things in the raw layer. |
| `footnote` | `footnote` | |

### The three ingestion columns

Every raw table carries `_source_file`, `_ingested_at` and `_batch_id`, so that
"where did this row come from and when did it arrive" is answerable without
guessing. `_ingested_at` is also what the incremental staging model selects on,
because it catches the case a file name does not: the SEC republishing a
corrected archive under the same name.
