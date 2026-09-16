# Analytical scope

The pipeline loads all 26,085 filings the SEC published in 2025. The **analysis**
is deliberately narrower: ten companies in one industry.

A hundred unrelated companies produce a hundred numbers that cannot be compared.
Ten companies in the same line of business produce a comparison, which is what a
financial analysis is. This document states which ten, and the criteria that
selected them.

**Reproduce it:**

```
duckdb data/db/sec_edgar.duckdb < analysis/00_scope_selection.sql
```

That query is the decision. It returns exactly the ten rows below.

---

## Contents

_Each entry states its decision; open one for the measurements behind it._

- [The scope](#the-scope)
- [Criteria](#criteria)
- [Why eating and drinking places](#why-eating-and-drinking-places)
- [What the scope supports](#what-the-scope-supports)
- [Constraints this scope imposes](#constraints-this-scope-imposes)
- [Limitations](#limitations)

---

## The scope

<details open>
<summary><b>Ten eating and drinking places in SIC 5810 and 5812, all closing in December,
all having filed a complete 2025 cycle.</b> 40 filings and 22,604 reported facts, spanning
the business model of the industry end to end: McDonald's at a 45.2% FY2024 operating
margin, Bloomin' Brands at 3.5%.</summary>

Ranked by FY2024 revenue. The last three columns measure how much of each statement is
written in the shared US-GAAP vocabulary rather than in one the company invented, which is
what decides whether two of these rows can be compared at all.

| # | CIK | Company | SIC | FY2024 revenue | FY2024 operating margin | Standard tags | Custom tags | % standard facts |
|---|---|---|---|---|---|---|---|---|
| 1 | 0000063908 | McDonald's | 5812 | 25.92 bn USD | 45.2% | 112 | 16 | 92.2 |
| 2 | 0001058090 | Chipotle Mexican Grill | 5812 | 11.31 bn USD | 16.9% | 103 | 3 | 98.3 |
| 3 | 0001673358 | Yum China Holdings | 5812 | 11.30 bn USD | 10.3% | 103 | 15 | 93.0 |
| 4 | 0001618756 | Restaurant Brands International | 5812 | 8.41 bn USD | 28.8% | 129 | 10 | 93.3 |
| 5 | 0001041061 | Yum! Brands | 5812 | 7.55 bn USD | 31.8% | 103 | 6 | 97.8 |
| 6 | 0001289460 | Texas Roadhouse | 5812 | 5.37 bn USD | 9.6% | 107 | 11 | 91.4 |
| 7 | 0001546417 | Bloomin' Brands | 5812 | 3.95 bn USD | 3.5% | 145 | 20 | 95.5 |
| 8 | 0000887596 | Cheesecake Factory | 5812 | 3.58 bn USD | 5.0% | 102 | 10 | 87.1 |
| 9 | 0000030697 | Wendy's | 5810 | 2.25 bn USD | 16.5% | 103 | 15 | 93.4 |
| 10 | 0000901491 | Papa John's International | 5812 | 2.06 bn USD | 7.6% | 131 | 8 | 97.3 |

Of those facts, 11,242 are consolidated company level figures and the rest are
segment breakdowns. The ten use 379 distinct standard tags and 114 custom ones.

The margin spread is not dispersion for its own sake, and it is not a difference
in how well these companies are run. McDonald's earns its margin on royalties
from restaurants it does not operate, roughly 95% of them franchised. Bloomin'
Brands operates the restaurants it owns and carries their payroll, rent and food
cost. Same industry, opposite cost structure, and the difference is reported
rather than inferred.

</details>

---

## Criteria

<details>
<summary><b>Six criteria narrow 7,151 companies to ten, and not one of them is a
judgement about which companies are interesting.</b> The same industry, a complete 2025
filing cycle, a December year end, the accounts a comparison needs, no duplicate registrant,
then size as the tie breaker.</summary>

### 1. The same industry

Operating margins are only comparable inside a single line of business. A
retailer and a bank do not have the same cost structure, so a chart placing them
side by side is not an analysis.

**This is two SIC codes, not one, and the reason is a property of the source.**
SIC 5812 is "eating places" and SIC 5810 is "eating and drinking places". They
name the same industry, and which one a company reports is its own choice:

| SIC | Companies in the data | Includes |
|---|---|---|
| 5812 | 51 | McDonald's, Chipotle, Texas Roadhouse, Yum! Brands, Cheesecake Factory |
| 5810 | 10 | Starbucks, Wendy's, Shake Shack, Dutch Bros, Luckin Coffee |

Filtering on 5812 alone would exclude Wendy's while including Burger King, which
belongs to Restaurant Brands International. The two compete directly. That is a
classification artifact deciding the analysis, which is the opposite of what a
criterion is for.

**Domino's Pizza cannot be recovered this way at all.** It files under SIC 5140,
wholesale groceries. Nothing about a pizza chain is wholesale groceries; the code
is simply wrong, and it is the filer's own declaration. See the limitations.

### 2. A complete filing cycle in 2025

Present in all four quarterly archives with **exactly one `10-K` and three
`10-Q`**. This is stricter than "appears four times", and the distinction
matters, because the archives are built by filing date rather than by accounting
period. A calendar year company files its annual report in the first archive and
its three quarterly reports in the next three:

| Archive | Filing | Period covered |
|---|---|---|
| 2025q1 | `10-K` | fiscal year ending 2024-12-31 |
| 2025q2 | `10-Q` | quarter ending 2025-03-31 |
| 2025q3 | `10-Q` | quarter ending 2025-06-30 |
| 2025q4 | `10-Q` | quarter ending 2025-09-30 |

All ten companies match this pattern exactly. Verified filing by filing.

4,477 of 7,151 companies pass this test. It also excludes Darden Restaurants,
which files one `10-K` and **four** `10-Q` inside the calendar year because its
fiscal year ends in May.

### 3. December fiscal year end

Companies whose fiscal year ends in June or September report a "third quarter"
that covers different calendar months. Requiring `fye = 1231` removes that
distortion instead of correcting for it.

### 4. The accounts a financial comparison needs

Reported as consolidated US dollar facts using the standard taxonomy: total
assets, the balance sheet total, equity, revenue, a bottom line, and operating
income.

Each account accepts **every standard tag companies actually use for it**, not
one canonical tag. This is not a convenience: as measured in
[`data_quality.md`](data_quality.md), requiring the single obvious tag would drop
companies for a reporting choice rather than for a missing account.

- Requiring `Liabilities` would exclude McDonald's, which reports only
  `LiabilitiesAndStockholdersEquity` and leaves total liabilities to be derived.
  534 of the 4,477 candidates do the same.
- Requiring `NetIncomeLoss` would exclude Texas Roadhouse and Restaurant Brands,
  which report `ProfitLoss` because they consolidate noncontrolling interests.
  Across the full data set, 2,907 companies use `ProfitLoss`.

Cost of revenue is **not** required, because only 46.13% of candidates report it.
Gross margin is therefore out of reach for a sector wide comparison, and
operating margin is the finest margin that generalises. That is a property of
the source rather than of the selection, so it carries to any analysis built on
this scope.

2,876 companies pass all criteria to this point, 42 of them in the two SIC codes
of the scope.

### 5. No duplicate registrants

Restaurant Brands International files twice: as the parent corporation, CIK
1618756, and as its operating partnership, CIK 1618755. Both report 8.41 bn USD
of FY2024 revenue and a 28.8% operating margin, because they are the same
business. Only the parent is kept.

This is the kind of duplicate that survives every referential integrity check,
because nothing about it is broken. It is caught by knowing the source, not by
testing it.

### 6. The ten largest by FY2024 revenue

The scope is capped at ten companies. Size is the tie breaker
because larger filers report more completely and more consistently, and because
the smallest companies in the sector produce ratios that swing on rounding: the
bottom of the list includes companies with 10 million USD of revenue and a -77.9%
operating margin.

The cut falls at 2.06 bn USD. **BJ's Restaurants is the eleventh**, at 1.36 bn
USD and a 1.0% operating margin, followed by Dutch Bros, Shake Shack and Red
Robin. Red Robin, at -4.3%, is the nearest loss making case if one is wanted
later.

</details>

---

## Why eating and drinking places

<details>
<summary><b>Chosen over five other sectors for a 44.2 point margin spread that has a
structural explanation.</b> A sector where every company earns the same margin gives the
analysis nothing to explain, and one whose spread has no explanation gives it nothing to
say.</summary>

Six sectors were measured against the same criteria. The deciding column is
margin dispersion, and the basis it is measured on has to be stated with it.

Dispersion is measured over **the twelve largest qualifying companies with at
least 500 million USD of FY2024 revenue**, on a December fiscal year end, with
duplicate registrants removed. Stating the basis matters, because a raw minimum
and maximum over every company in a sector is decided by one distressed outlier
rather than by the sector's structure.

| SIC | Sector | Qualified | December year end | FY2024 operating margin range | Spread |
|---|---|---|---|---|---|
| **5810 + 5812** | **Eating and drinking places** | **42** | **31** | **1.0% to 45.2%** | **44.2 pp** |
| 7011 | Hotels and casinos | 18 | 18 | -10.5% to 29.3% | 39.8 pp |
| 3674 | Semiconductors | 73 | 45 | -22.0% to 34.9% | 56.9 pp |
| 7372 | Prepackaged software | 159 | 112 | -29.5% to 29.1% | 58.6 pp |
| 5500 | Auto dealers | 14 | 13 | -11.4% to 10.2% | 21.6 pp |
| 4911 | Electric services | 30 | 30 | 8.6% to 26.4% | 17.8 pp |

Two of the six spread wider than this one, so spread by itself decides
nothing. What decides it is that here the driver is reported rather than
inferred: the franchised against company operated split is filed as a segment
breakdown, on axes such as `ProductOrService`. An analysis can point at the
column that produces the difference instead of asserting the difference.

The rejected alternatives, briefly:

- **Software and semiconductors** show a wider spread, but its driver is
  investment stage rather than business model, which is harder to defend as a
  thesis. Both also scatter across fiscal year ends, so the December subset
  excludes the best known names.
- **Electric services** has the cleanest data of all six, with a median of 134
  standard tags per company and all 30 candidates on a December year end. But its
  17.8 point spread is what regulated monopolies look like. Excellent input,
  little to say with it.
- **Auto dealers** are highly comparable and equally flat, at 21.6 points and
  every large one between 3% and 7%.

</details>

---

## What the scope supports

<details>
<summary><b>Three complete fiscal years and six quarterly periods per company, every one
of them read from the comparatives inside the filings rather than from the filing
dates.</b> The fourth quarter is never reported directly and has to be derived.</summary>

**Quarterly series.** Every company reports revenue for six quarterly periods:
Q1 to Q3 of 2024 and Q1 to Q3 of 2025. That comes from the comparatives carried
inside each `10-Q`, not from the filing dates alone, and it means **three
quarters of genuine year over year comparison.** Bloomin' Brands reports eleven
periods, reaching back to 2023.

**Annual series.** Every company reports full year revenue for FY2022, FY2023 and
FY2024, again through the comparatives inside the `10-K`. Three complete years.

**Fourth quarter is never reported directly.** No company files a `10-Q` for its
fourth quarter; the annual report covers it. A standalone Q4 has to be derived as
the full year minus the first three quarters, and that derivation must be labelled
as derived wherever it appears.

</details>

---

## Constraints this scope imposes

<details>
<summary><b>Three constraints carry forward to any comparison built on these ten
companies.</b> Operating margin rather than gross, a fourth quarter that is derived rather
than reported, and one company whose market is not the market of the other nine.</summary>

None of the three is a defect in the selection. Each is a measured property of
the source that the selection inherits, and a comparison that does not state
them reports a figure it cannot defend.

- **Operating margin, not gross margin.** Cost of revenue is reported by 12 of
  the 42 qualifying companies in the sector, so a gross margin comparison covers
  under a third of the field while looking sector wide.
- **Q4 is derived, not reported.** It is the full year less the first three
  quarters, so it inherits the error of four reported figures and has to be
  labelled as derived wherever it appears.
- **Yum China operates entirely in China.** It reports in US dollars under the
  same SIC code and meets every criterion, but its market is not the market of
  the other nine, and any margin comparison including it should say so.

Reversing the selection means redoing every comparison built on it, which is why
the criteria above are written down rather than remembered.

</details>

---

## Limitations

<details>
<summary><b>The scope is defined by what filers declared, not by what they do.</b> The
SIC code is the weakest link in it: self reported, validated by nobody, and the thing every
criterion here ultimately rests on.</summary>

- Ten companies is a comparison, not a statistical sample. Nothing here supports a
  claim about the restaurant industry as a whole.
- **The industry code carries no validation.** 88 companies across the data set
  report more than one code over the four quarters; the two codes this scope uses
  name the same business; and Domino's Pizza files under 5140, wholesale
  groceries, so no filter on the industry can recover it.
- The December fiscal year end requirement excludes eleven qualifying companies
  in the same industry, among them **Starbucks**, Brinker, Jack in the Box and
  Cracker Barrel. Starbucks would otherwise be the largest company in the scope.
- Darden Restaurants is excluded by the filing cycle criterion, not by size: its
  May fiscal year end puts four `10-Q` inside the 2025 calendar year.
- FY2024 figures are used for ranking and were read from the annual filings loaded
  in the 2025q1 archive. Where a later filing restated one of them, the restated
  value is present in the data as well; see the restatement section of
  [`data_quality.md`](data_quality.md).

</details>
