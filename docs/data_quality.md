# Data quality profile of the raw layer

What the SEC Financial Statement Data Sets actually contain, measured before any
modelling decision was taken. Every figure below comes from the raw layer as
loaded, with no cleaning applied.

**Reproduce it:**

```
python src/load_raw.py
python src/profile_raw.py
```

`src/profile_raw.py` prints the query behind every number on this page. It opens
the warehouse read only, so profiling can never be the reason a figure changed.

**Scope of the profile:** calendar 2025, the four quarterly archives stacked into
four raw tables.

| Table | Grain | Rows |
|---|---|---|
| `raw.sub` | One filing | 26,085 |
| `raw.tag` | One accounting concept, per quarter | 348,770 |
| `raw.pre` | One presentation line | 2,965,835 |
| `raw.num` | One reported numeric fact | 14,621,539 |
| | | **17,962,229** |

Those 26,085 filings come from 7,151 companies across 402 SIC codes, plus 196
companies that report no industry code at all.

---

## Contents

_Each entry states its finding; open one for the measurements behind it._

- [Why profiling came before modelling](#why-profiling-came-before-modelling)
- [1. The same concept is reported under different tags](#1-the-same-concept-is-reported-under-different-tags)
- [2. Not every company reports every total](#2-not-every-company-reports-every-total)
- [3. Custom concepts dominate the vocabulary and not the volume](#3-custom-concepts-dominate-the-vocabulary-and-not-the-volume)
- [4. Facts cover durations the documentation does not enumerate](#4-facts-cover-durations-the-documentation-does-not-enumerate)
- [5. Segment breakdowns outnumber consolidated figures](#5-segment-breakdowns-outnumber-consolidated-figures)
- [6. Restatements are real, and the flag meant to signal them is not](#6-restatements-are-real-and-the-flag-meant-to-signal-them-is-not)
- [7. Company identity is not stable](#7-company-identity-is-not-stable)
- [8. Identifier formats are not what a reader assumes](#8-identifier-formats-are-not-what-a-reader-assumes)
- [9. Anomalies that survive into the loaded data](#9-anomalies-that-survive-into-the-loaded-data)
- [10. What is clean, and worth stating](#10-what-is-clean-and-worth-stating)
- [How each finding is tested](#how-each-finding-is-tested)
- [Limitations of this profile](#limitations-of-this-profile)

---

## Why profiling came before modelling

The dirt in this source is not the kind that is cleaned up after the fact. Three
of the findings below change the grain or the filters of the dimensional model,
and all three share the same failure mode: when they are missed, the pipeline
does not raise an error. It produces a number that is roughly double the truth
and looks entirely reasonable.

That is the argument for measuring first. The findings are grouped by what they
force a decision about.

---

## 1. The same concept is reported under different tags

<details open>
<summary><b>There is no single US-GAAP tag for revenue, and none for the bottom
line.</b> Four revenue tags are in use, 350 companies use more than one, and which one a
company picks is a reporting choice rather than a property of its business.</summary>

This is the only finding on this page that breaks comparison *between* companies
rather than within one. Across all `10-K` and `10-Q` consolidated US dollar
facts:

| Tag | Companies using it | Facts |
|---|---|---|
| `RevenueFromContractWithCustomerExcludingAssessedTax` | 2,476 | 20,577 |
| `Revenues` | 1,949 | 15,768 |
| `RevenueFromContractWithCustomerIncludingAssessedTax` | 456 | 3,502 |
| `RevenuesNetOfInterestExpense` | 36 | 307 |

Of the companies reporting revenue at all, 4,175 use exactly one of the three
main tags, **344 use two, and 6 use all three.**

The bottom line is split the same way:

| Tag | Companies using it | Facts |
|---|---|---|
| `NetIncomeLoss` | 5,593 | 58,220 |
| `ProfitLoss` | 2,907 | 24,048 |
| `NetIncomeLossAvailableToCommonStockholdersBasic` | 1,063 | 7,546 |
| `IncomeLossFromContinuingOperations` | 421 | 2,737 |

`ProfitLoss` is what a company reports when it consolidates noncontrolling
interests, so the split follows corporate structure rather than accounting
quality. Texas Roadhouse and Restaurant Brands International report `ProfitLoss`
and never `NetIncomeLoss`.

**Consequence.** Any metric definition has to coalesce over the accepted tags,
and the tag it actually used has to stay visible so the choice can be audited. A
comparison built on a single tag does not fail loudly. It silently drops every
company that picked another one and returns something that looks like a complete
sector.

</details>

---

## 2. Not every company reports every total

<details>
<summary><b>Total liabilities is absent for 534 companies that do report a balance sheet,
and cost of revenue for more than half of all filers.</b> Operating margin, at 74.38%
coverage, is the finest margin that generalises across an arbitrary set of
companies.</summary>

Measured over the 4,477 companies that filed a complete annual cycle in 2025,
one `10-K` and three `10-Q`:

| Account | Companies reporting it | % |
|---|---|---|
| `Assets` | 4,453 | 99.46 |
| `LiabilitiesAndStockholdersEquity` | 4,377 | 97.77 |
| Equity, either variant | 4,321 | 96.52 |
| Bottom line, `NetIncomeLoss` or `ProfitLoss` | 4,444 | 99.26 |
| `Liabilities` | 3,943 | **88.07** |
| Revenue, any of the three tags | 3,477 | 77.66 |
| `OperatingIncomeLoss` | 3,330 | 74.38 |
| Cost of revenue, either tag | 2,065 | **46.13** |

Two entries deserve attention, and neither absence is an error on the filer's
part.

**Total liabilities is not a required XBRL fact.** A company can present only the
balance sheet total and leave the reader to subtract equity. McDonald's, Brinker,
Jack in the Box, Cracker Barrel and Aramark all do exactly that. A leverage
metric keyed on the `Liabilities` tag reports those companies as having no data,
when what they have is a figure that has to be derived from the accounting
identity.

**Gross margin cannot be computed across an arbitrary set of companies.** A filer
that presents a single cost line is complying with the rules; it simply means the
input to the metric exists for fewer than half the field, so any sector wide
gross margin is computed on a self selected subset.

</details>

---

## 3. Custom concepts dominate the vocabulary and not the volume

<details>
<summary><b>96.24% of the concept catalogue is invented by filers and carries 8.54% of the
numbers.</b> 317,473 custom concepts against 12,388 standard ones, most of them appearing in a
single filing and comparable across nothing.</summary>

`version` is the discriminator: for a standard concept it names the taxonomy
(`us-gaap/2025`), and for a company specific one it holds the filing's own
accession number.

| | Distinct concepts | % of catalogue |
|---|---|---|
| Custom | 317,473 | **96.24** |
| Standard | 12,388 | 3.76 |

| | Facts | % of facts |
|---|---|---|
| Standard | 13,372,319 | **91.46** |
| Custom | 1,249,220 | 8.54 |

**Those two tables count different things, and both counts are needed.** The
catalogue is grained on `(tag_name, version)`, so the same standard element
appears once per taxonomy year and a custom concept once per filing that invented
it. Counted by distinct *name* instead, the source holds 5,700 standard tag names
and 106,849 custom ones. Any statement about "how many concepts" has to say which
of the two it means.

Taxonomies in use:

| Namespace | Facts | % |
|---|---|---|
| `us-gaap/2024` | 6,341,436 | 43.37 |
| `us-gaap/2025` | 6,301,306 | 43.10 |
| Company specific | 1,249,220 | 8.54 |
| `ifrs/2024` | 555,948 | 3.80 |
| `us-gaap/2023` | 84,948 | 0.58 |
| `ifrs/2025` | 63,783 | 0.44 |
| `ifrs/2023` | 21,318 | 0.15 |

**Consequence.** `dim_account` holds every concept with an `is_custom_tag` flag
rather than being filtered to the standard taxonomy, because the share of custom
tagging is itself one of the questions the project answers. The cost is a
dimension dominated by rows that appear in a single filing and can never be
compared across companies, which has to be stated wherever it is counted.

The IFRS rows matter for a different reason: 641,049 facts come from filers using
IFRS rather than US-GAAP, and those tag names do not overlap with the US-GAAP
ones at all.

</details>

---

## 4. Facts cover durations the documentation does not enumerate

<details>
<summary><b>88 distinct durations occur where the documentation implies three, and the
trap is not the long tail but the values 2 and 3.</b> A nine month year-to-date figure sits in
the same table as the three quarters that compose it, so an unconstrained sum lands near double
the truth with no error raised.</summary>

`qtrs` states how many quarters a fact spans. The SEC readme defines it as a
count of quarters and does not restrict the values, and the data uses that
latitude: the values run from 0 to 124.

| `qtrs` | Meaning | Facts | % |
|---|---|---|---|
| `0` | Balance at a point in time | 6,980,547 | 47.74 |
| `1` | One quarter | 2,916,915 | 19.95 |
| `2` | Half year | 1,116,962 | 7.64 |
| `3` | Nine months, year to date | 1,071,132 | 7.33 |
| `4` | Full year | 2,533,938 | 17.33 |
| `5` and above | Long tail across 83 values | 2,045 | 0.014 |

What makes `2` and `3` the trap rather than the long tail is that they are
legitimate. A half year and a nine month figure are correctly reported, correctly
typed and correctly keyed; nothing distinguishes them from the quarters in a
`SUM()` except a column nobody is forced to read. The long tail is the opposite
case: 2,045 rows, 0.014%, and visibly wrong on inspection.

The long tail is almost certainly filer error. 124 quarters is 31 years, and the
values appear on tags such as `StockIssuedDuringPeriodSharesNewIssues` and
`RestructuringCharges`, where such a span has no accounting meaning.

**Consequence.** The fact table needs an explicit, documented `qtrs` filter, and
the accepted values test is `(0, 1, 2, 3, 4)`, not `(0, 1, 4)`. The latter would
fail on 2,188,094 rows.

</details>

---

## 5. Segment breakdowns outnumber consolidated figures

<details>
<summary><b>57.76% of all facts are a segment breakdown of a figure that is also reported
consolidated.</b> Ignoring the column does not inflate a total at the margin; it more than
doubles it.</summary>

`segments` carries the XBRL axis and member a fact is broken down by: by region,
by business line, by product.

| | Facts | % |
|---|---|---|
| Segment breakdown | 8,445,022 | **57.76** |
| Consolidated | 6,176,517 | 42.24 |

Stable across the four quarters, between 56.9% and 58.9%. Zero rows have a null
`segments`: the loader preserves the empty string as empty rather than promoting
it to `NULL`, so "consolidated" and "unknown" stay distinguishable.

A consolidated fact and its breakdowns share the same tag, period, duration and
unit. Only `segments` separates them, which is why the column has to be part of
the key rather than an attribute hanging off it.

**Consequence.** `segments` is part of the natural key of the fact, and any
aggregate has to state whether it reads consolidated rows only. That is what
`is_consolidated` is for; the decision to keep the breakdown rather than filter
it out, and the three measurements behind it, are in
[`modeling_decisions.md`](modeling_decisions.md) section 2.

A related, smaller case: 156,404 facts (1.07%) carry a `coreg` value, meaning
they are attributed to a co-registrant subsidiary rather than to the filer. They
have the same duplication behaviour and 1,692 distinct co-registrants appear.

</details>

---

## 6. Restatements are real, and the flag meant to signal them is not

<details>
<summary><b>19,369 facts were reported with a changed value by a later filing, and
<code>prevrpt</code>, the field documented to signal exactly that, is set on 5 filings out of
26,085.</b> A usable definition of a restatement has to be built from the facts themselves
rather than read off a flag.</summary>

`prevrpt` is documented as marking a submission that was subsequently amended. It
is set on **5 filings (0.02%)**, and only one of those five is a `10-Q`. The rest
are an `S-4/A`, a `10-K/A`, an `S-1/A` and an `11-K/A` — amendments to
registration and benefit plan filings rather than corrections to a financial
statement.

The definition that can be measured instead is the same company reporting the
same standard fact, for the same period, duration and unit, in more than one
filing.

| | Count | |
|---|---|---|
| Distinct fact keys across `10-K` and `10-Q` | 9,795,654 | |
| Reported in more than one filing | 1,409,903 | 14.39% of keys |
| **Reported with a changed value** | **19,369** | 1.37% of repeated |
| Reported once and then left blank afterwards | 1,541 | |
| Held only by the `qtrs > 4` long tail the staging layer drops | 19 | |

Repetition is normal: every `10-Q` restates the prior year comparative. A
**changed** value is the restatement.

**The last two rows are why the count has to be taken on the typed layer.** In
the raw layer an unpopulated value is an empty string, which `count(distinct)`
treats as a value in its own right, so a figure reported once and then left blank
registers as a change. It is not one: a company that stops reporting a number is
not a company saying a different number. A withdrawn figure is a real event and
worth counting, separately. Read off the raw layer the last three rows above collapse
into a single count of 20,929, which is what that layer returns and what a query
written without the distinction will report.

**Which companies concentrate them, and why volume is the wrong measure.**
Counting restated facts rather than the rows they appear on, Franklin BSP Capital
leads with 408 and Azenta follows with 252. The share is the more informative
figure: Franklin BSP Capital's 408 are 6.6% of what it repeats, while Azenta
restated **252 of 402, or 62.7%**. A leaderboard ordered by volume names the
companies that file the most, not the ones that change their minds.

Separately, 1,193 filings (4.57%) are amendments, identified by a form type
ending in `/A`.

**Consequence.** This is the evidence base for business question 5, and it is why
the incremental load merges on the natural key rather than appending: a
restatement has to update the fact, not sit beside it. The reproducible
measurement, stating both filters with the rows each one discards, is
[`analysis/05_restatement_analysis.sql`](../analysis/05_restatement_analysis.sql).

</details>

---

## 7. Company identity is not stable

<details>
<summary><b>172 companies filed under more than one name, and the industry code they
declare is weaker still.</b> Two SIC codes name the same industry and the filer picks one; a
third places a large pizza chain in wholesale groceries.</summary>

| Finding | Count | Base | % |
|---|---|---|---|
| Companies filing under more than one name | 172 | 7,151 | 2.41 |
| Companies filing under more than one SIC code | 88 | 7,151 | 1.23 |
| Filings carrying a former name | 14,996 | 26,085 | 57.49 |
| Filings with no SIC code | 715 | 26,085 | 2.74 |
| Filings with no fiscal year end | 68 | 26,085 | 0.26 |

At most 3 names appear for one `cik`. The changes are real corporate events, not
typos: `SUNPOWER INC.` to `COMPLETE SOLARIA, INC.`, `UNITI GROUP INC.` to
`WINDSTREAM PARENT, INC.`, `COHERUS BIOSCIENCES, INC.` to
`COHERUS ONCOLOGY, INC.`.

**The 88 counts an absent code as a value.** For 7 of them the only difference
across the four quarters is that one filing carries no `sic` at all, so **81
companies report two different codes** and 7 report one code and a blank. The
distinction matters because the two cases need different handling: a blank is
missing data, a second code is a contradiction. [`modeling_decisions.md`](modeling_decisions.md)
section 5 uses the 81, because a type 1 dimension has to choose between competing
values and a blank is not a competing value.

**Consequence.** `dim_company` needs a stated rule for which name is current. At
2.41% of companies, a Type 2 slowly changing dimension is not justified for this
project; the last known name, with the change documented, is.

`sic` is declared by the filer and validated by nobody, and the effect is visible
without leaving a single industry:

| SIC | Label | Companies | Includes |
|---|---|---|---|
| 5812 | Eating places | 51 | McDonald's, Chipotle, Texas Roadhouse |
| 5810 | Eating and drinking places | 10 | Starbucks, Wendy's, Shake Shack, Dutch Bros |
| 5140 | Groceries, wholesale | | **Domino's Pizza** |

Two codes name the same industry and the filer picks one. A third places a pizza
chain in wholesale groceries. Any grouping by `sic` inherits those choices, so
sector level analysis has to name the codes it treats as equivalent rather than
grouping on the raw column. The scope of this project does exactly that; see
[`scope.md`](scope.md).

</details>

---

## 8. Identifier formats are not what a reader assumes

`cik` arrives **without leading zeros**: stored width ranges from 4 to 7
characters and not one of the 26,085 filings has a leading zero. `fye` does keep
its padding, with 4,798 filings starting in a zero, which confirms the loader is
faithful and the difference comes from the source.

**Consequence.** The SEC's own submissions API expects the padded form,
`https://data.sec.gov/submissions/CIK0000063908.json`. The incremental stage has
to left pad to 10 digits. Passing the value through unchanged returns 404.

---

## 9. Anomalies that survive into the loaded data

<details>
<summary><b>Seven anomalies survive the load, and every one of them is a property of the
source rather than of the loader.</b> Filer typos in period end dates, 138 duplicates on a key
the SEC declares unique, an undocumented eighth statement code, and acceptance timestamps that
legitimately precede the filing date.</summary>

**Period end dates outside any plausible range.** 565 facts (0.00386%), across
106 distinct date values and 264 filings, fall outside 2010 to 2027. The extremes
are `1011-12-31` and `2050-03-31`. These are filer typos.

**Duplicates on the key the SEC itself declares unique.** `num.txt` is documented
as unique on `(adsh, tag, version, ddate, qtrs, uom, segments, coreg)`. It is
not: 138 key groups are duplicated, covering 276 rows in 4 filings, and **134 of
those 138 carry two different values for the same key.** Small, but it means the
primary key of the fact table cannot be assumed unique without a stated
resolution rule.

The other three files hold to their declared keys exactly: zero duplicates on
`sub(adsh)`, `pre(adsh, report, line)` and `tag(tag, version)` within a quarter.

**An undocumented statement code.** `pre.stmt` is documented with seven values.
An eighth appears: the empty string, on 257 lines across 8 filings, confined to
the first two quarters. Seven of those eight filings are registration statements
(`S-1`, `S-1/A`, `S-4/A`, `F-4/A`, `POS AM`); one is a `10-Q`. An
`accepted_values` test listing the seven documented codes fails on this.

| `stmt` | Meaning | Lines | % |
|---|---|---|---|
| `BS` | Balance sheet | 957,056 | 32.27 |
| `CF` | Cash flow | 910,038 | 30.68 |
| `IS` | Income statement | 554,822 | 18.71 |
| `EQ` | Equity | 373,670 | 12.60 |
| `CI` | Comprehensive income | 78,717 | 2.65 |
| `UN` | Unclassifiable | 75,744 | 2.55 |
| `SI` | Schedule of investments | 15,531 | 0.52 |
| (empty) | Undocumented | 257 | 0.01 |

**Acceptance timestamps that precede the filing date.** 2,056 filings (7.88%)
report an `accepted` timestamp on an earlier calendar day than `filed`. This is
not corruption: EDGAR assigns the next business day as the filing date to
submissions accepted after the daily cutoff. A test asserting `accepted <= filed`
would fail on all 2,056. What is a genuine anomaly is the reverse: **2 filings
have a period end date later than their filing date.**

**Filings without detail.** 47 filings (0.18%) carry `detail = 0`, meaning only
the statement level figures were tagged. They contribute 11,961 facts (0.08%).
Most are `6-K` and `10-Q`.

**Multiple registrants.** 495 filings (1.90%) list more than one registrant,
`nciks > 1`, up to 13 on a single filing.

**Empty fiscal period markers.** `fp` and `fy` are empty on 1,400 filings
(5.37%), all of them non periodic forms such as `S-1` and `8-K`. `period` is
empty on only 4.

</details>

---

## 10. What is clean, and worth stating

<details>
<summary><b>Referential integrity is complete in both directions between all four files,
and not one of 13,966,434 populated values fails to parse as a number.</b> These are what make
the findings above findings rather than load errors.</summary>

Every check in this table passed outright.

| Check | Result |
|---|---|
| Facts pointing at a filing absent from `sub` | 0 |
| Presentation lines pointing at a filing absent from `sub` | 0 |
| Facts pointing at a concept absent from `tag` | 0 |
| Presentation lines pointing at a concept absent from `tag` | 0 |
| Values not parseable as a number | 0 of 13,966,434 populated |
| Concepts relabelled between quarters | 0 of 329,861 |
| Duplicates on `sub(adsh)` | 0 |
| Duplicates on `pre(adsh, report, line)` | 0 |

**Values and footnotes.** 655,105 facts (4.48%) have an empty value. The
expectation was that a footnote would explain them; it does not. Only **1,434 of
those 655,105 (0.22%) carry a footnote at all.** Footnotes are rare in general:
36,706 facts (0.25%) have one, and most are attached to facts whose value is
present.

**Sign.** 1,860,119 facts (13.32% of populated values) are negative, which is
expected for contra accounts and losses, and is the reason `crdr` in `tag.txt`
matters when validating sign.

**Units.** 134 distinct units of measure. USD covers 82.58%, `shares` 6.77% and
`pure` (ratios and percentages) 6.40%. The remaining 4.25% spans 131 units,
mostly foreign currencies led by CNY, CAD and EUR. **Mixing units in an
aggregation is arithmetic on incompatible quantities**, so `uom` is part of the
fact key and every measure filters on it.

</details>

---

## How each finding is tested

<details>
<summary><b>Ten of the 156 checks are expected to fail, and each declares the number it should
return in <code>meta.expected_failures</code> beside the test itself.</b> A declared count that
moves in either direction fails the load, so the figures on this page are re-measured on every
run rather than quoted from here.</summary>

**This page and the tests measure different layers, and the counts differ
accordingly.** Everything above is measured on the raw layer as loaded. The tests
run against staging, which drops the 2,045 facts whose duration exceeds four
quarters, and that accounts for both disagreements below exactly: 4 of the 565
out-of-range period ends and 74 of the 655,105 unpopulated values sit on rows
whose duration is above four quarters. The two `accepted_values` tests disagree
for a different reason: they return offending *values*, not rows, so a single
returned value covers all 257 lines it appears on.

| Finding | Test | In the raw layer | Declared |
|---|---|---|---|
| Durations above 4 quarters are filer error | `accepted_values` on `period_length_qtrs` | 2,045 facts | Passes — the rows are filtered out in `stg_num` |
| `statement_code` has an undocumented eighth value | `accepted_values_stg_pre_statement_code__…` | 257 lines | **1** value, the empty string |
| The same, carried into the dimension | `accepted_values_dim_statement_statement_code__…` | 257 lines | **1** |
| `balance_type` is neither `D` nor `C` | `accepted_values` on `balance_type` | 34,068 concepts | Passes — nulls are ignored, so it measures wrong values rather than absences |
| The fact natural key is not unique | `unique_stg_num_fact_natural_key` | 138 key groups | **138** |
| Every fact resolves to a filing, company and concept | `relationships` | 0 orphans | Passes |
| `value` is unpopulated | `not_null_stg_num_value` | 655,105 facts | **655,031** |
| The same, inside the analytical scope | `not_null_fct_financial_facts_value` | — | **67** |
| Two concepts ship with no label at all | `not_null_stg_tag_tag_label` | — | **2** |
| Period end dates outside 2010 to 2027 | `assert_fact_period_end_within_plausible_range` | 565 facts | **561** |
| A filing whose period ends after it was filed | `assert_filing_period_end_not_after_filed_date` | 2 filings | **2** |
| A company filing under more than one name | `assert_one_company_name_per_cik` | 172 companies | **172** |
| A concept whose declared period type contradicts its own facts | `assert_fact_duration_matches_concept_period_type` | — | **33** |

A check that fails and is documented is worth more than one that always passes.
The ten counts in bold are properties of the source that the model answers for,
and none of them was softened to let a build through: all 156 checks run at
`error` severity.

The comparison is enforced rather than read.
[`src/load_dq_results.py`](../src/load_dq_results.py) reads what each check
actually returned, compares it against what the check declared, and exits
non-zero if any pair disagrees — so a documented failure that shrinks is as loud
as one that grows. Every run lands in `etl.dq_check_results`, which gives the
suite a history instead of only a latest result.

</details>

---

## Limitations of this profile

- It covers calendar 2025 only. Earlier years may carry different tag mixes as
  the US-GAAP taxonomy changes annually.
- Facts whose `ddate` falls in earlier years are present as comparatives, but
  those periods are not covered completely; 2024 and 2025 period ends account for
  80.23% of facts.
- The profile reads the raw layer. It measures what the SEC published, not what
  the companies meant.
