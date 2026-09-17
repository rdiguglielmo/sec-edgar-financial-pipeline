# Modelling decisions

Several properties of this source force a choice before any model can be
written, and most of them share a failure mode: taken silently, they produce a
number that is roughly double the truth and raises no error. This page records
the choice made for each one, the alternatives that were weighed, and the
figures each was weighed against.

Every figure here was measured against the loaded data. "In scope" means the
forty `10-K` and `10-Q` filings of the ten companies in [`scope.md`](scope.md),
which hold 22,604 of the 14,621,539 reported facts.

Decisions 1 to 4 belong to the staging layer and are implemented in
[`dbt/models/staging/stg_num.sql`](../dbt/models/staging/stg_num.sql). Decisions
5 to 9 belong to the marts and are implemented across
[`dbt/models/marts/`](../dbt/models/marts). Decision 10 covers how both layers
are written when new data arrives. Each carries the row count it costs written
next to it in the model itself.

---

## Contents

_Each entry states its decision; open one for the measurements behind it._

- [1. Which durations enter the fact](#1-which-durations-enter-the-fact)
- [2. Consolidated figures or the full breakdown](#2-consolidated-figures-or-the-full-breakdown)
- [3. Duplicates on the key the SEC declares unique](#3-duplicates-on-the-key-the-sec-declares-unique)
- [4. What the staging layer covers](#4-what-the-staging-layer-covers)
- [5. Company identity: last known name or a versioned history](#5-company-identity-last-known-name-or-a-versioned-history)
- [6. Which presentation line a fact belongs to](#6-which-presentation-line-a-fact-belongs-to)
- [7. How the analytical scope reaches the marts](#7-how-the-analytical-scope-reaches-the-marts)
- [8. What the marts cover](#8-what-the-marts-cover)
- [9. One economic fact, several filings](#9-one-economic-fact-several-filings)
- [10. Which models are incremental, and with which write strategy](#10-which-models-are-incremental-and-with-which-write-strategy)
- [What the model deliberately does not decide](#what-the-model-deliberately-does-not-decide)

---

## 1. Which durations enter the fact

<details open>
<summary><b>The double counting hazard stays in the table on purpose, made visible as a
column rather than filtered away.</b> Nine of the ten companies report interim cash flow only
as a year-to-date figure, so the filter that removes the hazard also removes the cash flow
statement.</summary>

`qtrs` states how many quarters a fact spans: `0` a value at a point in time,
`1` a quarter, `2` a half year, `3` nine months year to date, `4` a full year.
88 distinct values occur, from 0 to 124.

**The hazard.** A year to date figure sits in the same table as the individual
quarters that compose it. McDonald's operating cash flow for 2025 is filed as
2,428 million for the first quarter, 1,998 for the second, 3,428 for the third,
and 7,854 for the nine months. Summing the value column returns 15,708 when the
answer is 7,854. Nothing about that is detectable after the fact.

| Duration | All filings | Share | In scope | Share |
|---|---|---|---|---|
| `0`, `1`, `4` | 12,431,400 | 85.02% | 17,469 | 77.28% |
| `2`, `3`, year to date | 2,188,094 | 14.96% | 5,135 | 22.72% |
| `5` to `124` | 2,045 | 0.014% | **0** | 0% |

### Decision

**Keep `0` to `4`. Drop `5` and above, 2,045 rows. Add `is_year_to_date`.**

Values above 4 are filer error rather than a period: 124 quarters is 31 years,
and they appear on tags such as `StockIssuedDuringPeriodSharesNewIssues` and
`RestructuringCharges`, where such a span has no accounting meaning. None of the
2,045 belongs to a company in the scope.

Keeping `2` and `3` keeps the double counting hazard in the table on purpose.
The alternative was to remove it by filtering, and the cost of that was
measured:

- 137 concepts and 751 facts in the scope appear **only** as a year to date
  figure and never as a discrete quarter. 128 of those concepts belong to the
  cash flow statement and 9 to the statement of stockholders' equity.
- **Nine of the ten companies report interim operating cash flow only as year to
  date.** Only McDonald's files the discrete quarter. Filtering to `(0, 1, 4)`
  would leave the other nine with cash flow for the first quarter and the three
  full years, and nothing in between.

So the hazard is not removable without removing the cash flow statement. It is
instead made visible: `is_year_to_date` and `period_length_qtrs` are both
columns of the fact, and every aggregate has to state which duration it means.
That converts a silent error into a deliberate choice.

### Rejected

- **Keep only `0`, `1`, `4`.** The model could never double count. Costs 5,135
  facts in the scope and the interim cash flow statement of nine companies.
- **Keep all 88 values.** Maximum fidelity to the source, at the price of an
  `accepted_values` test that has to enumerate 88 values or be abandoned, and of
  2,045 facts spanning up to 31 years sitting in a fact table for no analytical
  purpose.

</details>

---

## 2. Consolidated figures or the full breakdown

<details>
<summary><b>The segment breakdown is kept in full, 8,445,022 rows that restate a total
already present.</b> The thesis of the scope, franchised against company operated, is reported
only as a breakdown, so filtering it out would remove the question rather than the
noise.</summary>

`segments` carries the XBRL axis and member a fact is broken down by. Empty
means the consolidated, company level figure. A consolidated fact and each of
its breakdowns share the same tag, period, duration and unit; only `segments`
separates them.

| | All filings | Share | In scope | Share |
|---|---|---|---|---|
| Breakdown | 8,445,022 | 57.76% | 11,362 | 50.27% |
| Consolidated | 6,176,517 | 42.24% | 11,242 | 49.73% |

### Decision

**Keep everything. `segments` stays part of the natural key. Add
`is_consolidated`.**

Three measurements decided it.

**The core comparison does not need the breakdown.** All ten companies report
their consolidated revenue completely: thirteen consolidated revenue facts each,
twenty-one for Bloomin' Brands. Revenue, operating income and margin come out of
the consolidated rows alone.

**Dropping the breakdown would remove whole concepts, not just detail.** 57
concepts and 416 facts in the scope exist **only** as a breakdown, mostly the
share movements of the statement of stockholders' equity: `SharesIssued`,
`StockRepurchasedAndRetiredDuringPeriodShares`,
`StockIssuedDuringPeriodSharesShareBasedCompensation`. By statement, the scope
splits like this:

| Statement | Consolidated facts | Breakdown facts |
|---|---|---|
| Income statement | 2,971 | 6,363 |
| Stockholders' equity | 1,441 | 4,140 |
| Balance sheet | 3,271 | 1,848 |
| Cash flow | 3,646 | 1,016 |
| Comprehensive income | 992 | 512 |

**The thesis of the scope lives in the breakdown.** The franchised versus
company operated split, which is the structural reason this industry has a 44
point margin spread, is only reported as a segment breakdown: Chipotle files
11,247 million under `ProductOrService=FoodAndBeverage`, Restaurant Brands
2,919 million under `ProductOrService=RoyaltyPropertyRevenueandFranchisor`.

That last point comes with a caveat worth stating here rather than discovering
downstream. **Members are named by the filer, so they do not line up across
companies.** The scope uses 468 distinct segment strings and **438 of them are
used by exactly one company.** Only two are used by all ten,
`EquityComponents=CommonStock` and `EquityComponents=RetainedEarnings`. Any
cross company segment comparison needs a mapping written by hand, and that
mapping is analysis, not modelling.

| Axis | Facts in scope | Companies | Distinct members |
|---|---|---|---|
| `BusinessSegments` | 4,944 | 10 | 230 |
| `EquityComponents` | 4,097 | 10 | 19 |
| `ConsolidationItems` | 797 | 6 | 32 |
| `ProductOrService` | 531 | 8 | 41 |
| `Geographical` | 196 | 3 | 17 |

`segments` is preserved as an empty string rather than converted to `NULL`,
because empty carries meaning here: it is the consolidated total, not a missing
value. Nulling it would also break the natural key.

A related column behaves the same way. `coreg` names a co-registrant subsidiary
a fact is attributed to, empty when the fact belongs to the filer. It is
populated on 156,404 facts (1.07%) across 1,692 co-registrants, and on **zero**
facts in the scope.

### Rejected

- **Consolidated rows only.** Removes the double counting hazard entirely, at a
  cost of 8,445,022 facts, the statement of stockholders' equity, and every
  segment level question.
- **Split the string into axis and member columns.** Useful, but not here: 123
  segment strings in the scope carry three axes and 4 carry four, so it is not a
  two column split. It belongs to the marts, where the axes that matter are
  known.

</details>

---

## 3. Duplicates on the key the SEC declares unique

<details>
<summary><b>Both rows of all 138 duplicated keys are kept, and the <code>unique</code> test
is allowed to fail.</b> They are two real forward currency positions colliding on an identifier
the filer reused, and every rule that would make the test pass picks one of them at random and
calls it a decision.</summary>

`num.txt` is documented as unique on
`(adsh, tag, version, ddate, qtrs, uom, segments, coreg)`. It is not.

| | Count |
|---|---|
| Duplicated key groups | 138 |
| Rows involved | 276, exactly two per group |
| Groups with two different values | 134 |
| Filings involved | 4 |
| Companies involved | **1** |
| Groups in the analytical scope | **0** |

All four filings come from Ares Strategic Income Fund, CIK 1918712, a business
development company that declares no SIC code. All 138 groups sit on the
schedule of investments and on three standard US-GAAP tags:
`DerivativeLiabilityNotionalAmount` (54), `DerivativeAssetFairValueGrossLiability`
(54) and `DerivativeAssetNotionalAmount` (30). All carry `qtrs = 0`.

**What the duplicates are.** The `segments` value reads
`OpenForwardForeignCurrencyContractIdentifier=, Wells Fargo Bank, N.A. 3;` — an
identifier per forward currency contract. The two rows are two real, distinct
positions that collide because the fund reused one identifier for several of
them. They are not a load artifact and not a rounding artifact: the median
absolute difference between the two values is 3,245,000 and the maximum is
109,733,000.

**Why no resolution rule works.** The pair is not a sign flip that could be
normalised away: 85 groups hold two non negative values, 35 hold two non
positive values, 14 hold values of opposite sign, and **none** is the exact
negative of the other. Nothing in the row distinguishes which position each
value belongs to. Any rule that picks one is picking at random and calling it a
decision.

### Decision

**Keep both rows. Flag them with `has_duplicate_natural_key`. Let the `unique`
test fail on 138 keys, documented.**

The fact's primary key becomes the surrogate `fact_natural_key` rather than a
key that can be declared unique, and a downstream model joining on it fans out
to two rows in 276 cases out of 14,619,494. The flag exists so that fan out is
excluded deliberately rather than discovered.

The failing test is the point. A `unique` test that passes because the awkward
rows were deleted says nothing; one that fails on exactly 138 keys, with the
filer, the tags and the reason recorded, says that the source contradicts its
own documentation and that the model knows it.

### Rejected

- **Deduplicate on the larger absolute value.** The key becomes genuinely
  unique and the test passes. Costs 138 rows that are real positions, under a
  rule with no accounting justification.
- **Drop both rows of every conflicting group,** 268 rows, and deduplicate the
  four identical groups. Invents nothing, but leaves a test that passes because
  the case was removed rather than answered.

</details>

---

## 4. What the staging layer covers

<details>
<summary><b>Staging is a typed, renamed projection of the whole source: 26,085 filings and
14.6 million facts, not the forty filings of the scope.</b> The scope is a property of the
analysis rather than of the source, and filtering it in here would leave every quality check
measuring 0.15% of the filings.</summary>

It would also remove the base that business question 4, the share of custom
against standard tagging, is asked about. The scope filter belongs to the marts,
where it can be stated once against a dimension and inherited by everything that
joins to it.

The four models therefore mirror the four source files one to one, with one
exception that is a property of the source rather than a filter:

| Model | Rows in | Rows out | Difference |
|---|---|---|---|
| `stg_sub` | 26,085 | 26,085 | none |
| `stg_tag` | 348,770 | 329,861 | 18,909 repeat copies of a concept |
| `stg_pre` | 2,965,835 | 2,965,835 | none |
| `stg_num` | 14,621,539 | 14,619,494 | 2,045 rows above `qtrs = 4` |

`tag.txt` is a catalogue shipped inside every quarterly archive, so a concept
used in more than one quarter arrives once per archive. Deduplicating it is
lossless, and that was verified rather than assumed: **zero of the 329,861
concepts disagree with themselves on any attribute across quarters**, including
label and documentation text. The row kept is the one from the most recent
archive.

</details>

---

## 5. Company identity: last known name or a versioned history

<details>
<summary><b>A type 2 dimension would hold exactly the same ten rows as a type 1, so the
model takes the type 1.</b> None of the ten companies changed its name during 2025, and
versioning would buy a date range join on the fact to represent a change that does not
occur.</summary>

`dim_company` can hold one row per company carrying the last known value of
every attribute, a type 1 dimension, or one row per version of the company with
a validity range, a type 2. The second is the standard answer when history
matters, and the question is whether it matters here.

What actually moves between filings, across all 7,151 companies:

| Attribute that changes | Companies | Share |
|---|---|---|
| Name | 172 | 2.41% |
| SIC code | 81 | 1.13% |
| Business state | 178 | 2.49% |
| Business country | 282 | 3.94% |
| Fiscal year end | 90 | 1.26% |
| **Any of them** | **682** | **9.54%** |

Each row counts companies reporting two *different* values. A further 7 companies
report a SIC code on some filings and none on others, which
[`data_quality.md`](data_quality.md) counts as a change and this table does not:
an absent value is missing data, not a competing value, and a type 1 dimension
only has to choose between competing values.

And what each design costs in rows:

| Design | Whole data set | In scope |
|---|---|---|
| Type 1, last known value | 7,151 | **10** |
| Type 2 on the name | 7,324 | **10** |
| Type 2 on every attribute | 7,857 | **11** |

### Decision

**Type 1, the last known value, taken from each company's most recently filed
filing with ties broken by accession number.**

The measurement that decides it is the third column. **None of the ten companies
in the scope changed its name during 2025**, so a type 2 dimension keyed on the
name holds exactly the same ten rows as a type 1. Versioning every attribute
would add a single row, because Restaurant Brands files two different business
state values, and it would add it for a change no analysis asks about.

The cost avoided is not the extra row, it is the join. A type 2 forces the fact
to resolve which version was current on the filing date, and a range join
written loosely multiplies the fact. That is the one thing the marts layer is
not allowed to do, and it would be introduced here to represent a change that
does not occur.

"Last known" has to name a rule or it means whichever row the database happened
to return, which is why the ordering is stated in the model.

The rule is not silent. `assert_one_company_name_per_cik` still fails on all 172
renaming companies at the staging layer on every run, so the rate that justifies
this choice is re-measured rather than quoted, and a jump in it means the choice
needs revisiting.

### Rejected

- **Type 2 on the name.** The textbook answer to a changing attribute, and here
  it produces an identical dimension at the price of a date range join on the
  fact.
- **Type 2 on every attribute.** Full history, one extra row, and the same join
  risk for a change of registered address.

A type 2 earns its cost where a changing identity is part of the business case
rather than an event that does not occur in the sample. That is a property of the
domain, not a default to reach for whenever an attribute can change.

</details>

---

## 6. Which presentation line a fact belongs to

<details>
<summary><b>The fact carries exactly one statement, resolved by a stated rule, because
joining to the presentation table inflates the scope by 24.3%.</b> 22,604 facts match 28,103
fact and line pairs, and 2,938 of them genuinely fall on more than one statement.</summary>

`pre.txt` has one row per presentation line, and a concept appears on several
lines of the same filing. Joining a fact to it fans out, which is the failure
this layer exists to prevent.

Measured on the scope: **22,604 facts match 28,103 fact and line pairs, a 24.3%
inflation.** Every figure joined that way is wrong by that much.

| | Facts in scope | Share |
|---|---|---|
| On exactly one line | 19,236 | 85.1% |
| On more than one line | 3,368 | 14.9% |
| Whose lines cross statements | 2,938 | 13.0% |
| **On parenthetical lines only** | **665** | **2.9%** |
| With no presentation line at all | **0** | 0% |

The statements being disputed are the ordinary ones: 81 concept groups appear on
both the cash flow statement and the income statement, 50 on both comprehensive
income and equity, 36 on both the balance sheet and equity. Depreciation
genuinely belongs to two statements.

### Decision

**`dim_statement` holds one row per statement code, eight rows. The fact carries
one `statement_key`, resolved by preferring a line that is not parenthetical,
then the lowest report number, then the lowest line number.**

Three things follow from that, each measured.

**Parenthetical lines are preferred against, not excluded.** A parenthetical line
is a disclosure carried beside a statement line, common stock par value beside
common stock, so it is the weaker answer to "which statement is this on". But
665 facts in the scope appear on parenthetical lines only, and a filter would
leave those with no statement at all. Preferring costs nothing; excluding costs
665 classifications.

**Where the rule chooses, the choice is recorded.** Ordering by position rather
than by a statement preference changes the answer on 18 of the 4,545 groups in
the scope, and a rule ranking the income statement first would change 54. No
ordering is defensible on accounting grounds for a concept that really does
appear on two statements, so the model takes the first line as filed and flags
the rest: `has_multiple_statement_lines` on 3,368 facts,
`spans_multiple_statements` on 2,938. The full mapping is not destroyed; it
stays in `stg_pre`.

**The resolution is asserted, not assumed.**
`assert_fact_keeps_every_scope_row` compares the fact against its source rows and
`assert_fact_does_not_fan_out_over_dimensions` compares it against itself joined
to all five dimensions. Both return 22,604.

### Rejected

- **A dimension at presentation line grain.** 4,968 rows for 22,604 facts inside
  the scope, one dimension row per four and a half facts, every row specific to
  a single filing so nothing conforms across companies. What an analysis slices
  by is the statement, and there are eight of those.
- **A bridge table with no `statement_key` on the fact.** Loses nothing and
  invents nothing: all 28,103 pairs are kept. It also means every aggregate cut
  by statement inflates by 24.3% unless the query is written by someone who
  knows, which is exactly the class of silent error this project is built to
  avoid.

</details>

---

## 7. How the analytical scope reaches the marts

<details>
<summary><b>The roster of ten companies exists in exactly one file, read by both dbt and
Python.</b> A roster written twice does not fail when the copies drift: the extractor refreshes
one set of companies while the marts analyse another, and both runs complete.</summary>

The roster is defined by the six criteria in [`scope.md`](scope.md), and it has
to reach SQL somehow. dbt cannot read Python, and the Python stages need the same
list to decide which companies to refresh.

### Decision

**A dbt seed, `dbt/seeds/scope_companies.csv`, is the single place the roster
exists. dbt reads it with `ref()`, and `src/config.py` reads the same file with
the standard library `csv` module.**

`dim_company` joins to it, and every other model inherits the filter by joining
to `dim_company` or `dim_filing`, so the scope is stated once and applied five
times without being repeated.

The failure this avoids is specific. A roster written twice does not raise an
error when the copies drift: the extractor refreshes one set of companies and
the marts analyse another, and both run to completion. The same applies inside
the seed itself, which is why `cik` is loaded as text through an explicit
`column_types` in `dbt_project.yml`. Read as a number, `0000063908` becomes
`63908`, every join returns nothing, and the scope silently becomes empty.

`assert_scope_roster_is_complete` checks both directions, every seed row
reaching `dim_company` and every company reaching the seed, plus the one `10-K`
and three `10-Q` per company that criterion 2 of [`scope.md`](scope.md) promised.

### Rejected

- **A dbt variable in `dbt_project.yml`.** Shortest, no new file, and the list
  lives in Python and in YAML with nothing keeping them in step. It also cannot
  carry the rank or the label.
- **Generating the seed from `config.py`.** Keeps Python as the source of truth
  at the price of a build step that has to be remembered.
- **Re-deriving the six criteria as a dbt model.** The most reproducible option,
  since the criteria are the definition rather than the list, and the most
  complex model in the repository. It also lets the scope move on its own when
  new data arrives, which is the opposite of what a stable comparison needs from
  it.

</details>

---

## 8. What the marts cover

<details>
<summary><b>The marts are conformed to the ten companies, which takes the Parquet export
from about 640 MB to 683 KB.</b> The export is committed so the repository can be read without
running anything, and GitHub rejects files over 100 MB.</summary>

The fact could hold the scope or the whole source, and the dimensions could
follow it or not.

| Model | Whole source | Conformed to the scope |
|---|---|---|
| `dim_company` | 7,151 | 10 |
| `dim_filing` | 26,085 | 40 |
| `dim_account` | 329,861 | 1,066 |
| `fct_financial_facts` | 14,619,494 | 22,604 |
| Parquet export | about 640 MB | **683 KB** |

### Decision

**The fact holds the 22,604 facts of the scope, and each dimension covers
exactly what the fact references.**

Two numbers decided it. The export is the hard one: GitHub rejects files over
100 MB and the exported marts are committed so that the repository can be read
without running anything, so a 640 MB fact table cannot be part of a repository
that anyone can clone and open. The second is that an unconformed dimension is dead weight
inside Power BI as well as in the warehouse: `dim_account` at full breadth would
be 329,861 rows of which 1,066 join to anything.

**What this costs, stated rather than discovered.** Two of the five business
questions are about the source rather than about the ten companies, and inside
the scope they lose their base:

| Question | Whole data set | In scope |
|---|---|---|
| 4, custom versus standard tagging | 106,845 custom names against 5,700 standard, 8.54% of facts | 114 against 379, 5.91% |
| 5, restatements | **19,369** facts reported with a changed value, on the staging layer | **2** |

Question 4 still has an answer at scope level, and a narrower one is arguably
more honest than a catalogue wide average. Question 5 does not: two goodwill
adjustments are an anecdote, not an analysis. Both are therefore answered
against the staging layer in `analysis/`, which covers all 26,085 filings, and
that is a property of the question rather than a gap in the model.

### Rejected

- **Scope fact, full dimensions.** Keeps question 4 answerable from the marts at
  catalogue level, at the cost of a dimension where 99.7% of rows join to
  nothing.
- **Full fact with an `is_in_scope` flag.** Everything answerable in one place,
  and a 640 MB Parquet file that cannot be committed, plus every analysis query
  carrying a filter that the model was supposed to have applied once.

</details>

---

## 9. One economic fact, several filings

<details>
<summary><b>1,840 of the 22,604 scope facts are superseded by a later filing, and not one of
them is removed.</b> This hazard behaves exactly like the durations and the segment
breakdowns: it inflates a total quietly, so it becomes a column rather than a
filter.</summary>

Every `10-Q` restates the prior year comparative, so the same company, concept,
period, duration, unit and breakdown is filed again by a later filing. In the
scope, **22,604 fact rows carry only 20,764 distinct economic facts.**

The fact carries `economic_fact_key`, the natural key with the filing replaced by
the company, and two flags derived from it:

- `is_latest_report`, true on the surviving version of each economic fact, 20,764
  rows.
- `is_restated`, true when an earlier filing reported a different value for the
  same key. **Two facts in the scope**, both goodwill, and both revised
  downwards in the first quarterly report after the annual one: Yum! Brands from
  92 to 88 million at 2024-04-30, reported in the `10-K` of 2025-02-19 and again
  in the `10-Q` of 2025-05-07, and Restaurant Brands from 481 to 479 million at
  2024-05-31, in the `10-K` of 2025-02-21 and the `10-Q` of 2025-05-08.

**The direction is the whole content of the fact.** A company revising goodwill
down has written some off; a company revising it up has found more. Both readings
are arithmetically consistent with the same pair of numbers, so the flag is only
useful if the earlier and later versions stay distinguishable, which is what
`is_latest_report` is for. Both facts are reproduced by
[`analysis/05_restatement_analysis.sql`](../analysis/05_restatement_analysis.sql),
whose third result set returns them with the filing date of every version.

That makes three flags on this fact for three different double counting hazards,
`is_year_to_date`, `is_consolidated` and `is_latest_report`, and the pattern is
the same each time: the rows stay, the ambiguity becomes a column, and every
aggregate has to state which one it means.

</details>

---

## 10. Which models are incremental, and with which write strategy

<details>
<summary><b>Both incremental models upsert, but on different strategies, and the difference
is forced by 138 rows.</b> DuckDB's <code>MERGE</code> silently keeps one row of a duplicated
key and drops the other, which would turn a documented failing test green for the wrong
reason.</summary>

The pipeline reloads a bulk snapshot that the SEC republishes quarterly, so
every model faces the same question: reprocess everything, or only what
arrived. Two properties of this source decide it, and they point in opposite
directions for the two layers.

| Model | Rows | Materialisation | Strategy | Key |
|---|---|---|---|---|
| `stg_num` | 14,619,494 | incremental | `delete+insert` | `fact_natural_key` |
| `fct_financial_facts` | 22,604 | incremental | `merge` | `fact_key` |
| `stg_sub`, `stg_pre`, `stg_tag`, `stg_filing_index` | up to 3.0M | view | n/a | n/a |
| the five dimensions | up to 3,653 | table, full rebuild | n/a | n/a |

### Decision

**`stg_num` uses `delete+insert` and the fact uses `merge`, and the difference
is forced by 138 rows.**

Both strategies upsert, which is the property that matters: a row arriving with
a key that is already present replaces it rather than joining it. `append` would
duplicate 14.6 million rows the first time an archive is reloaded. The choice
between the two upserts is where the measurement comes in.

`stg_num` holds 138 natural keys with two rows each, 276 rows, 134 of those
pairs carrying different values. Tested directly against DuckDB with a two row
source sharing one key: **`MERGE` keeps one row and drops the other, raising
nothing**, while `delete+insert` keeps both. A merge strategy on this model
would therefore delete 138 rows on every incremental run, and
`unique_stg_num_fact_natural_key`, which currently fails on exactly 138 keys,
would begin to pass. A test that passes because rows were deleted is worse than
one that fails honestly, and the 138 are real positions rather than noise. That
was established by measurement: two distinct values on every one of the 134
conflicting keys, a median absolute difference of 3,245,000 USD, no sign
relationship between the pairs, and no column in the row that could tell them
apart. See decision 3.

Inside the analytical scope the same key is unique on all 22,604 rows, measured:
zero duplicates. The fact can therefore use `merge` safely, and it is the model
where the semantics are worth demonstrating, because it is the grain a
restatement is defined on.

### What the two strategies actually do

Both are upserts, and dbt presents them as interchangeable ways to spell the same
intent. They are not. They differ in what they treat as the unit of work, and
that difference only becomes visible when a key is not unique.

**`delete+insert` works on sets of keys.** dbt collects the distinct keys present
in the incoming batch, deletes every target row holding one of them, and then
inserts the batch whole:

```sql
delete from target
where  fact_natural_key in (select fact_natural_key from batch);

insert into target
select * from batch;
```

Nothing in either statement inspects an individual row. Whatever arrives with a
given key replaces whatever was there under that key, however many rows that is
on either side.

**`merge` works on pairs of rows.** One statement walks the batch against the
target and decides, per match, whether to update or insert:

```sql
merge into target
using  batch
on     target.fact_key = batch.fact_key
when matched     then update set value = batch.value, ...
when not matched then insert values (...);
```

The `on` clause is a join, and a join is only well defined here if each target
row matches at most one source row.

**The same batch, run through both.** Take a key that already holds one row in
the target, and a batch that carries two rows under it — which is exactly the
shape of the 138 groups in `stg_num`:

| | Target before | Batch | `delete+insert` leaves | `merge` leaves |
|---|---|---|---|---|
| key `A` | one row, value 10 | two rows, values 40 and 70 | **both**, 40 and 70 | **one**, 40 or 70 |
| key `B` | absent | one row, value 5 | one row, 5 | one row, 5 |
| key `C` | one row, value 3 | absent | untouched, 3 | untouched, 3 |

Key `A` is the whole story. `delete+insert` removes the old row and inserts two,
because it never asked how many rows share the key. `merge` finds two source rows
competing to update one target row, and DuckDB resolves the ambiguity by applying
one of them and discarding the other **without raising anything** — verified
directly against the engine rather than inferred from the documentation. Other
warehouses are stricter: Snowflake errors under `ERROR_ON_NONDETERMINISTIC_MERGE`
and BigQuery raises on a duplicated match. DuckDB does not, so on this engine the
data loss is silent.

| | `delete+insert` | `merge` |
|---|---|---|
| Unit of work | a key | a pair of rows |
| A key with several rows | keeps all of them | keeps one, silently, on DuckDB |
| Cost of changing one row in a group | rewrites the whole group | updates that row |
| Requires the key to be unique | no | **yes** |
| Fits | a natural key the source does not honour | a key measured to be unique |

Neither is the better strategy in general. `merge` expresses the intent more
directly and touches less data, which is why it is the obvious default. It is the
wrong default on a model whose entire purpose is to preserve a key collision that
the source created and the documentation denies.

### Full rebuild, upsert, and what each one guarantees

The requirement behind this decision is one sentence: a restatement has to update
the fact rather than sit beside it. There are two ways to end up satisfying it,
and only one of them is a guarantee.

**A full rebuild throws the table away.** `dbt run` on a `table` materialisation
issues `create or replace table fct_financial_facts as select ...`, so every run
produces the table from scratch out of whatever staging currently holds. No row
is ever updated, because no row survives.

**An upsert keeps the table and rewrites part of it.** Rows whose key arrives in
the batch are replaced; every other row is left where it is. The write statement
names the key and states what happens on a match.

Now take a **correction on an existing key**: the SEC republishes an archive under
the same name with one figure changed, so a row arrives carrying a key already in
the table and a different `value`.

- **Under the full rebuild** the new value appears. But look at why. Nothing
  matched the key, nothing decided to overwrite anything: the old row is gone
  because *every* row was discarded, and the new one is present because staging
  now reads that way. The correct outcome is a by-product of how the table is
  built.
- **Under the upsert** the new value appears because `merge ... on fact_key` found
  the key and `when matched then update` said what to do about it. The outcome is
  a property of the statement that was written.

That is the distinction between **a property of the materialisation** and **a
guarantee of the write**, and it matters because materialisations change for
reasons that have nothing to do with correctness. The day the fact outgrows a
one-second rebuild and someone switches it to incremental for speed, the full
rebuild's accidental correctness disappears — and it disappears **silently**, in
whichever direction the new strategy happens to take. Under `append` the old and
corrected rows would both be present and every total would be wrong. Nothing
fails, no test necessarily catches it, and the requirement was never written down
anywhere a reader could check it against the code.

The guarantee is also the only version that can be demonstrated. The simulation
recorded below — one scope fact rewritten in the raw layer with a different value
and a later timestamp, then `dbt run`, then the same row counts and the new value
in both layers — proves something about the upsert. Run against a full rebuild the
identical test passes trivially, because any table reconstructed from scratch
matches its input. A test that cannot fail is not evidence.

This is why the fact is incremental despite being small. 22,604 rows rebuild in
about a second, and an incremental run still touches a third of them, so there is
no performance argument at all. It is incremental because the requirement asked
for an upsert, and an upsert is something a model either performs or does not.

### What the incremental batch is, and why the fact's is wider than its input

`stg_num` selects on `_ingested_at`, not on the source file name. Both catch a
new quarter, but only the timestamp catches the case that matters more: the SEC
republishing a corrected archive under the same name. That row arrives with the
same natural key and a later ingestion stamp, and the write replaces it.

Two properties measured on the loaded data make the batched window function
safe. Zero of the 26,085 accession numbers appear in more than one quarterly
archive, and zero natural keys span two archives, so
`has_duplicate_natural_key`, computed within one batch, sees every row of every
group it flags.

The fact's batch is **not** the newly landed rows. Three of its columns are
computed by comparing filings rather than within a row: `economic_fact_key`,
`is_latest_report` and `is_restated`. Whether a row is still the current version
of its economic fact depends on every other filing reporting the same fact,
including rows already in the table. Processing only new rows would mark the new
version current and leave the superseded one marked current as well, and the
total would double for exactly the rows the flag exists to protect. So the batch
is every row sharing an `economic_fact_key` with a new row, and the merge
rewrites the older members of each group with recomputed flags.

Measured against the last archive loaded, 2025q4: it contributes 6,591 new rows
and the lookback widens the batch to 7,797, **34.5% of the table**. That
widening is structural rather than particular to this quarter, because every
10-Q restates the prior year comparative and therefore reopens groups that
already exist.

### What the merge does not cover, and why the flags stay

The requirement this implements was written as "a restatement updates the fact
rather than sitting beside it". Measured against this source, that sentence
covers two different events and the strategy only covers one of them.

- **The same filing republished with a corrected figure.** Same natural key,
  later ingestion. The upsert replaces it. Verified by simulation: one scope
  fact was rewritten in the raw layer with a different value and a later
  timestamp, and after `dbt run` both `stg_num` and the fact held the same row
  counts as before, one row for that key, and the new value in both layers.
- **A later filing reporting a different figure for the same economic fact.**
  This is a *different* natural key, because the key contains the filing, so no
  merge strategy on that key can collapse the two. It is also not something to
  collapse: both rows are genuine reports made at different times, and decision
  9 keeps both with `economic_fact_key`, `is_latest_report` and `is_restated`.
  Overwriting them would delete the evidence for business question 5.

The five dimensions stay full rebuilds. `dim_company` is a type 1 dimension
holding each company's last known name, which is decided against every filing
rather than against the newest batch, and `dim_account` is conformed to the
fact, so both need the whole input. None exceeds 3,653 rows.

Both incremental models share one limitation, stated rather than discovered: a
row that a republished archive no longer contains is not deleted, because an
incremental model only ever sees what arrived. `dbt run --full-refresh` rebuilds
`stg_num` in about 39 seconds and the whole project in about 43.

### Rejected

- **`append` on either model.** The only strategy that never has to identify a
  key, and the one that turns a reloaded archive into 14.6 million duplicate
  rows with no error.
- **`merge` on `stg_num`.** Matches the fact's strategy and reads consistently,
  at the cost of 138 silently deleted rows per run and a documented failing test
  turning green for the wrong reason.
- **Leaving the fact as a full rebuild.** Simplest and correct today, at the
  price of holding the requirement by accident rather than by construction. See
  the subsection above: a rebuild that happens to produce the right answer stops
  producing it the moment the materialisation changes, and it cannot be tested.

</details>

---

## What the model deliberately does not decide

<details>
<summary><b>Two questions are left to the analysis layer on purpose: which tags mean revenue,
and how segment members map across companies.</b> Both are judgements about meaning rather than
about structure, and a model that answers them buries the judgement inside a column where
nobody can audit it.</summary>

The distinction is not a matter of taste. A modelling decision can be defended
with a row count: the choices above each name the facts they keep, the facts they
drop and the alternatives they beat. Neither of the two below can. They are
defensible only with an argument about what a number means, and an argument
belongs in a query that states it, next to the result, where a reader can
disagree with it.

- **Which tags mean revenue, and which mean the bottom line.** No single US-GAAP
  tag carries either; the measurements are in
  [`data_quality.md`](data_quality.md). A metric definition has to coalesce over
  the accepted tags and keep the tag it actually used visible, so the choice can
  be audited per row. Putting that coalesce in the fact would freeze one reading
  of revenue into the grain, and every downstream figure would inherit it without
  saying so.
- **Mapping segment members across companies.** The franchised against company
  operated split, which is the thesis of the scope, exists only as a breakdown,
  and 438 of the 468 segment strings in the scope are used by exactly one company.
  A cross company comparison needs a mapping written by hand, and a hand written
  mapping that lives in a dimension looks like a fact.

Both are answered in [`../analysis/`](../analysis), where each query opens by
declaring the tags it accepted and the flags it applied.

</details>
