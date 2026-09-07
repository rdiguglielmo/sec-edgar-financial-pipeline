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

_Each section expands on click._

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
- [Findings carried into the test layer](#findings-carried-into-the-test-layer)
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
<summary>This is the finding with the widest reach, because it breaks comparison between companies...</summary>

This is the finding with the widest reach, because it breaks comparison between
companies rather than within one.

**There is no single US-GAAP tag for revenue.** Across all `10-K` and `10-Q`
consolidated US dollar facts:

| Tag | Companies using it | Facts |
|---|---|---|
| `RevenueFromContractWithCustomerExcludingAssessedTax` | 2,476 | 20,577 |
| `Revenues` | 1,949 | 15,768 |
| `RevenueFromContractWithCustomerIncludingAssessedTax` | 456 | 3,502 |
| `RevenuesNetOfInterestExpense` | 36 | 307 |

Which tag a company uses is a reporting choice, not a property of its business.
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

**Consequence.** Any metric definition has to be a coalesce over the accepted
tags, and the tag actually used has to stay visible in the model so the choice
can be audited. A comparison built on one tag does not fail loudly; it silently
drops every company that picked another one.

</details>

---

## 2. Not every company reports every total

<details>
<summary>Measured over the 4,477 companies that filed a complete annual cycle in 2025, one 10-K and...</summary>

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

Two entries deserve attention.

**`Liabilities` is absent for 534 companies that do report a balance sheet.**
Total liabilities is not a required XBRL fact: a company can present only the
balance sheet total and leave the reader to subtract equity. McDonald's,
Brinker, Jack in the Box, Cracker Barrel and Aramark all do exactly that. A
leverage metric keyed on the `Liabilities` tag would report those companies as
having no data rather than as having a derivable figure.

**Cost of revenue is reported by fewer than half.** Gross margin therefore cannot
be computed across an arbitrary set of companies. Operating margin, at 74.38%
coverage, is the most granular margin that generalises.

</details>

---

## 3. Custom concepts dominate the vocabulary and not the volume

<details>
<summary>version is the discriminator: for a standard concept it names the taxonomy (us-gaap/2025), and...</summary>

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

**96% of the vocabulary carries 8.5% of the numbers.** 5,700 distinct standard
tag names account for the overwhelming majority of reported facts, while 106,849
distinct custom tag names account for the rest.

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

**Consequence.** `dim_account` will hold every concept with an `is_custom_tag`
flag rather than being filtered to the standard taxonomy, because the share of
custom tagging is itself one of the questions the project answers. But the
dimension is dominated by rows that appear in a single filing and can never be
compared across companies, and that has to be stated wherever it is counted.

The IFRS rows matter for a different reason: 641,049 facts come from filers using
IFRS rather than US-GAAP, and those tag names do not overlap with the US-GAAP
ones at all.

</details>

---

## 4. Facts cover durations the documentation does not enumerate

<details>
<summary>qtrs states how many quarters a fact spans.</summary>

`qtrs` states how many quarters a fact spans. The SEC readme defines it as a
count of quarters and does not restrict the values.

| `qtrs` | Meaning | Facts | % |
|---|---|---|---|
| `0` | Balance at a point in time | 6,980,547 | 47.74 |
| `1` | One quarter | 2,916,915 | 19.95 |
| `2` | Half year | 1,116,962 | 7.64 |
| `3` | Nine months, year to date | 1,071,132 | 7.33 |
| `4` | Full year | 2,533,938 | 17.33 |
| `5` and above | Long tail across 83 values | 2,045 | 0.014 |

**88 distinct values appear, from 0 to 124.**

The trap is not the long tail; it is `2` and `3`. A nine month year to date
figure sits in the same table as the three individual quarters that compose it.
Summing the value column without constraining `qtrs` adds the same money twice
and produces a total near double the truth, with no error raised.

The long tail is almost certainly filer error: 124 quarters is 31 years, and the
values appear on tags such as `StockIssuedDuringPeriodSharesNewIssues` and
`RestructuringCharges`, where such a span has no accounting meaning.

**Consequence.** The fact table needs an explicit, documented `qtrs` filter, and
the accepted values test is `(0, 1, 2, 3, 4)`, not `(0, 1, 4)`. The latter would
fail on 2,188,094 rows.

</details>

---

## 5. Segment breakdowns outnumber consolidated figures

<details>
<summary>segments carries the XBRL axis and member a fact is broken down by: by region, by business...</summary>

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
unit. Only `segments` separates them. Ignoring the column does not inflate totals
at the margin; it more than doubles them.

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
<summary>prevrpt is documented as marking a submission that was subsequently amended.</summary>

`prevrpt` is documented as marking a submission that was subsequently amended.
It is set on **5 filings out of 26,085 (0.02%)**, and only one of those five is a
`10-Q`. The rest are an `S-4/A`, a `10-K/A`, an `S-1/A` and an `11-K/A`.

As a restatement signal it is unusable. The measurable definition is different:
the same company reporting the same standard fact, for the same period, duration
and unit, in more than one filing.

| | Count | % |
|---|---|---|
| Distinct fact keys across `10-K` and `10-Q` | 9,795,654 | |
| Reported in more than one filing | 1,409,903 | 14.39 of keys |
| Reported with a changed value, as first counted | 20,929 | 1.48 of repeated |

Repetition is normal: every `10-Q` restates the prior year comparative. A
**changed** value is the restatement.

> **Corrected 2026-08-06, and the correction is the point.** The 20,929 above is
> counted over the raw layer, where an unpopulated value is an empty string and
> therefore counts as a value in its own right. Under that reading a figure
> reported once and then left blank registers as a change, which it is not. The
> same definition applied to the typed staging layer, where an empty value is
> null and `count(distinct)` ignores it, separates the two:
>
> | | Count |
> |---|---|
> | **The number changed between filings** | **19,369** |
> | The figure was reported once and left blank afterwards | 1,541 |
> | Keys held only by the `qtrs > 4` long tail the staging layer drops | 19 |
> | Total, reproducing the original figure | 20,929 |
>
> A withdrawn figure is a real event and worth counting. It is not a company
> saying a different number.
>
> **The company leaderboard first published here has been removed rather than
> corrected, because it could not be reproduced.** It named Franklin BSP Capital
> (1,632 facts), Azenta (1,008), ECD Automotive Design (952), Profusa (870) and
> Moog (705), and no combination of the recorded filters returns those counts:
> the companies are right, the numbers came from an ad hoc query whose
> definition was not written down. Counting restated facts rather than the rows
> they appear on, Franklin BSP Capital leads with 408 and Azenta follows with
> 252.
>
> The reproducible version of this whole measurement is
> [`analysis/05_restatement_analysis.sql`](../analysis/05_restatement_analysis.sql),
> which states its two filters with the rows each discards and returns the
> leaderboard as part of its output.

Separately, 1,193 filings (4.57%) are amendments, identified by a form type
ending in `/A`.

**Consequence.** This is the evidence base for business question 5, and it is why
the incremental load has to merge on the natural key rather than append: a
restatement must update the fact, not sit beside it.

</details>

---

## 7. Company identity is not stable

<details>
<summary>10 rows: Finding, Count, Base, %</summary>

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

**Consequence.** `dim_company` needs a stated rule for which name is current. At
2.41% of companies, a Type 2 slowly changing dimension is not justified for this
project; the last known name, with the change documented, is.

**The industry code is weaker than the name.** `sic` is declared by the filer and
is not validated, and the effect is visible without leaving one industry:

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
<summary>Period end dates outside any plausible range.</summary>

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
<summary>Not every check found something.</summary>

Not every check found something. These passed outright and are the reason the
findings above can be trusted as findings rather than as load errors.

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

Referential integrity is complete in both directions between all four files.

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

## Findings carried into the test layer

<details>
<summary>These become dbt tests in week 2.</summary>

These become dbt tests in week 2. Recorded here with the number each one is
expected to catch on the current data.

| Check | Type | Expected result today |
|---|---|---|
| `qtrs` in `(0, 1, 2, 3, 4)` after filtering the long tail | `accepted_values` | Excludes 2,045 rows |
| `statement_code` in the seven documented values | `accepted_values` | **Fails on 257 rows** until the empty code is handled |
| `balance_type` in `(D, C)` | `accepted_values` | 34,068 concepts have neither, so nullable |
| Fact natural key unique | `unique` | **Fails on 138 keys** until a resolution rule is stated |
| Every fact resolves to a filing, company, concept | `relationships` | Passes, 0 orphans |
| `value` not null | `not_null` | Fails on 655,105 rows, documented exception |
| Period end date within 2010 to 2027 | singular | Flags 565 facts |
| Period end date not after the filing date | singular | Flags 2 filings |
| One current name per company | singular | Flags 172 companies before the naming rule is applied |
| Duplicate facts not explained by restatement | singular | 20,929 restated fact keys are the explained set |

A check that fails and is documented is worth more than one that always passes.
Four of the ten above are expected to fail on real data, and each failure is a
property of the source that the model has to answer for.

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
