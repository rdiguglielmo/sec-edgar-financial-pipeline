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

_Each section expands on click._

- [The scope](#the-scope)
- [Criteria](#criteria)
- [Why eating and drinking places](#why-eating-and-drinking-places)
- [What the scope supports](#what-the-scope-supports)
- [Coupling to project 02](#coupling-to-project-02)
- [Limitations](#limitations)

---

## The scope

<details open>
<summary>Eating and drinking places, SIC 5810 and 5812.</summary>

**Eating and drinking places, SIC 5810 and 5812.** Ten companies, all with a
December fiscal year end, all having filed a complete annual cycle in 2025.

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

Together they contribute 40 filings and 22,604 reported facts, of which 11,242
are consolidated. They use 379 distinct standard tags and 114 custom ones.

The scope spans the business model spectrum end to end: McDonald's earns 45.2%
with roughly 95% of its restaurants franchised, while Bloomin' Brands earns 3.5%
operating the restaurants it owns.

</details>

---

## Criteria

<details>
<summary>Each criterion is mechanical and reproducible.</summary>

Each criterion is mechanical and reproducible. None of them is a judgement about
which companies are interesting.

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
operating margin is the finest margin that generalises. This constrains the
analysis in project 02 and is recorded as such.

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
<summary>Six sectors were measured against the same criteria before choosing.</summary>

Six sectors were measured against the same criteria before choosing. The
deciding column is margin dispersion: a sector where every company earns the same
margin gives the analysis nothing to explain.

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

Spread alone is not the criterion. **A spread is only useful if it has a
structural explanation**, and in eating and drinking places it has one that is
visible in the data: franchisors collect royalties without carrying the cost of
operating the restaurants, while company operators carry both. McDonald's earns
45.2% with roughly 95% of its restaurants franchised; Bloomin' Brands earns 3.5%
operating the restaurants it owns.

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
<summary>Measured on the selected companies, not assumed.</summary>

Measured on the selected companies, not assumed.

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

## Coupling to project 02

<details>
<summary>This choice is not reversible without redoing the comparative analysis that follows.</summary>

This choice is not reversible without redoing the comparative analysis that
follows. The business questions in that project are answered on these ten
companies, so the constraints found here carry forward:

- Operating margin, not gross margin. Cost of revenue is reported by 12 of the 42
  qualifying companies in the sector.
- Q4 is derived, not reported.
- Yum China operates entirely in China. It reports in US dollars under the same
  SIC code and meets every criterion, but its market is not the same market as
  the other nine, and any margin comparison involving it should say so.

</details>

---

## Limitations

<details>
<summary>Ten companies is a comparison, not a statistical sample.</summary>

- Ten companies is a comparison, not a statistical sample. Nothing here supports a
  claim about the restaurant industry as a whole.
- **SIC codes are self reported and are not a rigorous taxonomy.** This is the
  weakest link in the scope. The same industry occupies two codes, one large
  chain files under wholesale groceries, and 88 companies across the data set
  report more than one SIC code over the four quarters. The scope is defined by
  what filers declared, not by what they do.
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
