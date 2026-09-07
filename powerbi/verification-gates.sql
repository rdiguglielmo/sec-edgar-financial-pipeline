-- Verification gates for the Power BI dashboard.
--
-- Every number the report shows is checked here against the warehouse first. The
-- expected result is written down BEFORE the query runs; if the two disagree the
-- report is wrong, not the expectation.
--
-- Read-only. Safe to run with Power BI Desktop open.


-- --- GATE 1 -----------------------------------------------------------------
-- Grain. One concept, ten companies, three years.
-- EXPECT: 30 rows, and "rows_at_this_grain" = 1 on every single one.
-- If any row shows 2 or more, every chart built on this measure double counts.
SELECT
    c.company_name,
    YEAR(f.period_end_key)      AS calendar_year,
    COUNT(*)                    AS rows_at_this_grain,
    SUM(f.value)                AS total_value
FROM marts.fct_financial_facts f
JOIN marts.dim_company c USING (company_key)
JOIN marts.dim_account a USING (account_key)
WHERE a.tag_name           = 'OperatingIncomeLoss'
  AND f.is_consolidated    = TRUE
  AND f.is_latest_report   = TRUE
  AND f.is_year_to_date    = FALSE
  AND f.unit_of_measure    = 'USD'
  AND f.period_length_qtrs = 4
GROUP BY 1, 2
ORDER BY 1, 2;


-- --- GATE 2 -----------------------------------------------------------------
-- The single number the DAX measure must reproduce.
-- EXPECT: exactly one row.
-- Whatever total_value this returns is what $ Annual Consolidated Value must
-- show in Power BI with McDonald's + 2024 + Operating Income (Loss) selected.
SELECT
    COUNT(*)     AS rows_at_this_grain,
    SUM(f.value) AS total_value
FROM marts.fct_financial_facts f
JOIN marts.dim_company c USING (company_key)
JOIN marts.dim_account a USING (account_key)
WHERE a.tag_name           = 'OperatingIncomeLoss'
  AND c.company_name       = 'MCDONALDS CORP'
  AND YEAR(f.period_end_key) = 2024
  AND f.is_consolidated    = TRUE
  AND f.is_latest_report   = TRUE
  AND f.is_year_to_date    = FALSE
  AND f.unit_of_measure    = 'USD'
  AND f.period_length_qtrs = 4;


-- --- GATE 3 -----------------------------------------------------------------
-- Data quality, LATEST BATCH ONLY. The table accumulates one row set per run:
-- it holds 468 rows, which is three runs of 156.
-- EXPECT: total_checks 156, passing 146, known_exceptions 10, unexpected 0.
WITH latest AS (
    SELECT batch_id
    FROM etl.dq_check_results
    ORDER BY run_at DESC
    LIMIT 1
)
SELECT
    COUNT(*)                                                    AS total_checks,
    COUNT(*) FILTER (WHERE status = 'pass')                     AS passing,
    COUNT(*) FILTER (WHERE status <> 'pass'
                       AND rows_failed = expected_rows_failed)  AS known_exceptions,
    COUNT(*) FILTER (WHERE status <> 'pass'
                       AND rows_failed <> expected_rows_failed) AS unexpected
FROM etl.dq_check_results
WHERE batch_id = (SELECT batch_id FROM latest);


-- --- GATE 3b ----------------------------------------------------------------
-- The ten, by name, with declared count beside actual.
-- EXPECT: 10 rows, and rows_failed = expected_rows_failed on all ten.
WITH latest AS (
    SELECT batch_id FROM etl.dq_check_results ORDER BY run_at DESC LIMIT 1
)
SELECT check_name, layer, rows_failed, expected_rows_failed, status
FROM etl.dq_check_results
WHERE batch_id = (SELECT batch_id FROM latest)
  AND status <> 'pass'
ORDER BY rows_failed DESC;


-- --- GATE 4 -----------------------------------------------------------------
-- The batch the four DQ cards pin to. `_Latest DQ Run` in the model returns a
-- batch_id; this is the one it has to return.
-- EXPECT: exactly 1 row, with checks_in_batch = 156.
-- first_row_at and last_row_at are expected to be EQUAL - one timestamp stamped
-- per run, not per row. The measure works either way, but if they differ it
-- means run_at is row-level and that is worth knowing before relying on it.
SELECT
    batch_id,
    MIN(run_at) AS first_row_at,
    MAX(run_at) AS last_row_at,
    COUNT(*)    AS checks_in_batch
FROM etl.dq_check_results
GROUP BY batch_id
ORDER BY MAX(run_at) DESC
LIMIT 1;


-- --- GATE 5 -----------------------------------------------------------------
-- Figures replaced by a later filing. The number `# Superseded Facts` must show
-- with nothing else filtered.
-- EXPECT: superseded 1,840, total_facts 22,604.
SELECT
    COUNT(*) FILTER (WHERE is_latest_report = FALSE) AS superseded,
    COUNT(*)                                         AS total_facts
FROM marts.fct_financial_facts;


-- --- GATE 6 -----------------------------------------------------------------
-- The concept picker. Summable annual flow concepts reported by all ten
-- companies, under EXACTLY the filter set `$ Annual Consolidated Value` applies
-- - so the picker cannot offer a concept the money measure cannot total.
-- EXPECT: exactly 9 rows, companies = 10 on every one, 'Operating Income (Loss)'
-- among them, and no EarningsPerShare tag.
--
-- Note: the earlier count of eleven qualifying concepts was taken without the
-- unit_of_measure filter. If this returns something other than 9, that is the
-- discrepancy to discuss - it is not an expectation to adjust.
SELECT
    a.tag_name,
    a.tag_label,
    COUNT(DISTINCT f.company_key) AS companies
FROM marts.fct_financial_facts f
JOIN marts.dim_account a USING (account_key)
WHERE f.is_consolidated    = TRUE
  AND f.is_latest_report   = TRUE
  AND f.is_year_to_date    = FALSE
  AND f.unit_of_measure    = 'USD'
  AND f.period_length_qtrs = 4
  -- per-share, not summable across companies
  AND a.tag_name NOT IN ('EarningsPerShareBasic', 'EarningsPerShareDiluted')
GROUP BY 1, 2
HAVING COUNT(DISTINCT f.company_key) = 10
ORDER BY 1;


-- --- GATE 7 -----------------------------------------------------------------
-- The picker keys on tag_label, not tag_name. dim_account holds more than one
-- tag VERSION per concept - OperatingIncomeLoss has two rows - and every version
-- of a concept shares one label, so the label is the thing a user should pick.
--
-- That is only safe if a label never spans two concepts. If one did, the picker
-- would silently merge two tags and `$ Annual Consolidated Value` would double
-- count them, with nothing failing to say so.
--
-- Scoped to the NINE the picker offers, derived here the same way gate 6 derives
-- them rather than listed by hand, so this gate cannot drift away from the list
-- it is meant to protect. An earlier version of this gate asked the question
-- over the whole of dim_account, where the answer is not zero - see gate 7b.
-- EXPECT: 0 rows.
WITH picker AS (
    SELECT a.tag_label
    FROM marts.fct_financial_facts f
    JOIN marts.dim_account a USING (account_key)
    WHERE f.is_consolidated    = TRUE
      AND f.is_latest_report   = TRUE
      AND f.is_year_to_date    = FALSE
      AND f.unit_of_measure    = 'USD'
      AND f.period_length_qtrs = 4
      AND a.tag_name NOT IN ('EarningsPerShareBasic', 'EarningsPerShareDiluted')
    GROUP BY a.tag_label, a.tag_name
    HAVING COUNT(DISTINCT f.company_key) = 10
)
SELECT
    a.tag_label,
    COUNT(DISTINCT a.tag_name) AS tag_names,
    COUNT(*)                   AS account_rows
FROM marts.dim_account a
WHERE a.tag_label IN (SELECT tag_label FROM picker)
GROUP BY a.tag_label
HAVING COUNT(DISTINCT a.tag_name) > 1
ORDER BY 1;


-- --- GATE 7b ----------------------------------------------------------------
-- The same question over the WHOLE dimension, where the answer is NOT zero.
--
-- Two labels each carry two tag_names that differ only in letter case - SARs
-- against Sars, To against to. These are custom tags, where the filer chooses
-- the spelling, so the drift is the issue emitter's and not the pipeline's.
-- Neither label is among the nine, so neither can reach the picker.
--
-- Declared rather than hidden, the same way the ten deliberate dbt failures
-- declare their counts. If a THIRD label ever turns up here, a label has started
-- spanning two tags for real and gate 7 above is the one to re-read.
-- EXPECT: exactly 2 rows - 'Employee Stock Option and SARs Exercises, Value' and
-- 'Tenant Inducements Paid to Franchisees' - with 2 tag_names and 4 account rows
-- each.
SELECT
    tag_label,
    COUNT(DISTINCT tag_name) AS tag_names,
    COUNT(*)                 AS account_rows
FROM marts.dim_account
GROUP BY tag_label
HAVING COUNT(DISTINCT tag_name) > 1
ORDER BY 1;


-- --- GATE 8 -----------------------------------------------------------------
-- The Data Confidence exception table groups on check_name, layer and status,
-- and reads two measures pinned to the latest batch. dq_check_results is
-- disconnected and accumulates one row set per run - 468 rows, three runs of
-- 156 - so that grouping is only safe if a check's identity is stable across
-- runs. If one check ever changed layer or status between runs it would render
-- as two rows, with nothing failing to say so.
-- EXPECT: 0 rows.
SELECT
    check_name,
    COUNT(DISTINCT layer)    AS layers,
    COUNT(DISTINCT status)   AS statuses,
    COUNT(DISTINCT batch_id) AS batches
FROM etl.dq_check_results
GROUP BY check_name
HAVING COUNT(DISTINCT layer) > 1
    OR COUNT(DISTINCT status) > 1
ORDER BY 1;


-- --- GATE 9 -----------------------------------------------------------------
-- What the Data Confidence exception table filters on.
--
-- The table shows the ten deliberate failures. "Not passing" cannot be expressed
-- as a PBIR filter without hard-coding the status vocabulary, but "rows failed
-- greater than zero" can, using the same Comparison structure already proven on
-- a measure filter elsewhere. That substitution is only honest if the two select
-- exactly the same checks.
-- EXPECT: 2 rows - fail with 10 checks and rows_failed from 1 to 655,031, pass
-- with 146 and rows_failed 0 on every one - and pass_with_rows and
-- fail_without_rows BOTH zero, which is what makes the two definitions the same
-- ten. If a status other than pass or fail ever appears here, the table's filter
-- is the thing to re-read.
WITH latest AS (
    SELECT batch_id FROM etl.dq_check_results ORDER BY run_at DESC LIMIT 1
)
SELECT
    status,
    COUNT(*)                                                  AS checks,
    MIN(rows_failed)                                          AS min_rows,
    MAX(rows_failed)                                          AS max_rows,
    COUNT(*) FILTER (WHERE status =  'pass' AND rows_failed <> 0) AS pass_with_rows,
    COUNT(*) FILTER (WHERE status <> 'pass' AND rows_failed =  0) AS fail_without_rows
FROM etl.dq_check_results
WHERE batch_id = (SELECT batch_id FROM latest)
GROUP BY status
ORDER BY 1;


-- --- GATE 10 ----------------------------------------------------------------
-- What lets Company Comparison show a change column PER COMPANY.
--
-- `% Value vs LY` anchors on the latest year where it is non-blank. Sector-wide
-- that is one anchor; evaluated inside a company row it is ten anchors, and if
-- one company were missing its 2024 annual figure that company would silently
-- be comparing 2023 against 2022 in a column headed 2024 vs 2023.
--
-- The nine concepts are already known to be reported by all ten companies -
-- that is gate 6 - but gate 6 says nothing about WHICH YEARS.
-- EXPECT: combinations_expected 270 (nine concepts x ten companies x three
-- annual years) and missing 0. Anything above zero and the per-company change
-- column comes off the page.
WITH picker AS (
    SELECT a.tag_label
    FROM marts.fct_financial_facts f
    JOIN marts.dim_account a USING (account_key)
    WHERE f.is_consolidated    = TRUE
      AND f.is_latest_report   = TRUE
      AND f.is_year_to_date    = FALSE
      AND f.unit_of_measure    = 'USD'
      AND f.period_length_qtrs = 4
      AND a.tag_name NOT IN ('EarningsPerShareBasic', 'EarningsPerShareDiluted')
    GROUP BY a.tag_label, a.tag_name
    HAVING COUNT(DISTINCT f.company_key) = 10
),
grid AS (
    SELECT p.tag_label, c.company_name, y.yr
    FROM picker p
    CROSS JOIN marts.dim_company c
    CROSS JOIN (VALUES (2022), (2023), (2024)) AS y(yr)
),
present AS (
    SELECT a.tag_label, c.company_name, YEAR(f.period_end_key) AS yr
    FROM marts.fct_financial_facts f
    JOIN marts.dim_account a USING (account_key)
    JOIN marts.dim_company c USING (company_key)
    WHERE f.is_consolidated    = TRUE
      AND f.is_latest_report   = TRUE
      AND f.is_year_to_date    = FALSE
      AND f.unit_of_measure    = 'USD'
      AND f.period_length_qtrs = 4
    GROUP BY 1, 2, 3
)
SELECT
    COUNT(*)                              AS combinations_expected,
    COUNT(*) FILTER (WHERE p.yr IS NULL)  AS missing
FROM grid g
LEFT JOIN present p
       ON p.tag_label = g.tag_label
      AND p.company_name = g.company_name
      AND p.yr = g.yr;


-- --- GATE 11 ----------------------------------------------------------------
-- The two year-over-year figures on Data Confidence. They anchor on 2025, the
-- latest year with ANY fact - not on 2024, the latest year with ANNUAL facts,
-- which is what `% Value vs LY` anchors on. That is why the two families cannot
-- share a card: they would read as one comparison and be two.
-- EXPECT: 2025 has 8,184 facts and 33 filings, 2024 has 10,471 and 40, so
-- `% Facts vs LY` must show -21.8% and `% Filings vs LY` must show -17.5%.
-- The handful of facts in 2016 and 2021 are period_end dates outside the loaded
-- quarters and do not touch either figure.
SELECT
    YEAR(period_end_key)         AS yr,
    COUNT(*)                     AS facts,
    COUNT(DISTINCT filing_key)   AS filings
FROM marts.fct_financial_facts
GROUP BY 1
ORDER BY 1;
