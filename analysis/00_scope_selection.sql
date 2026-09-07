-- Question: which companies belong in the analytical scope of this project?
--
-- The scope has to be decided from the data rather than picked by reputation,
-- and it has to be reproducible: this query is the decision. Running it against
-- the raw layer returns exactly the ten companies documented in docs/scope.md.
--
-- The criteria, in the order they are applied:
--
--   1. Same industry. Operating margins are only comparable inside one line of
--      business. Eating and drinking places was chosen because its margin
--      dispersion has a structural explanation rather than being noise:
--      franchisors collect royalties without carrying the cost of running the
--      restaurants, company operators carry both.
--
--      Two SIC codes, not one. 5812 "eating places" and 5810 "eating and
--      drinking places" name the same industry, and which one a filer uses is
--      its own choice: McDonald's, Chipotle and Texas Roadhouse report 5812
--      while Starbucks, Wendy's, Shake Shack and Dutch Bros report 5810.
--      Filtering on 5812 alone would drop direct competitors of companies that
--      are in the scope. Domino's cannot be recovered this way at all: it files
--      under 5140, wholesale groceries.
--   2. A complete filing cycle. The company appears in all four 2025 archives
--      with exactly one 10-K and three 10-Q. Four filings, no gaps.
--   3. December fiscal year end, so the reported quarters line up across
--      companies without a calendar adjustment.
--   4. The accounts a financial comparison needs, all reported as consolidated
--      US dollar facts: total assets, the balance sheet total, equity, revenue,
--      a bottom line and operating income.
--   5. Not a duplicate registrant. Restaurant Brands files twice, as the parent
--      corporation and as its operating partnership, with identical figures.
--   6. The ten largest by fiscal 2024 revenue. Larger filers report more
--      completely and more consistently, and the project brief caps the scope at
--      ten companies.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/00_scope_selection.sql

with filing_cycle as (
    -- Criterion 2 and 3.
    select
        cik,
        max(name) as company_name,
        max(sic)  as sic_code,
        max(fye)  as fiscal_year_end
    from raw.sub
    where form in ('10-K', '10-Q')
    group by cik
    having count(distinct substr(_source_file, 1, 6)) = 4
       and count(*) filter (where form = '10-K') = 1
       and count(*) filter (where form = '10-Q') = 3
       and max(fye) = '1231'
),

-- Consolidated facts only. A segment breakdown carries the same tag, period and
-- unit as the consolidated figure and differs only in the segments column, so
-- reading both would count the same money twice.
consolidated_facts as (
    select s.cik, n.tag, n.qtrs, n.ddate, n.value
    from raw.num n
    join raw.sub s using (adsh)
    where s.form in ('10-K', '10-Q')
      and n.version <> n.adsh   -- standard taxonomy, not a company specific tag
      and n.segments = ''
      and n.coreg = ''
      and n.uom = 'USD'
      and n.value <> ''
),

account_coverage as (
    -- Criterion 4. Each account accepts every standard tag companies actually
    -- use for it. Requiring one exact tag drops companies for a reporting
    -- choice rather than for a missing account: insisting on Liabilities alone
    -- would exclude McDonald's, which reports only the balance sheet total, and
    -- insisting on NetIncomeLoss alone would exclude Texas Roadhouse, which
    -- reports ProfitLoss because it consolidates noncontrolling interests.
    select
        cik,
        max(case when tag = 'Assets' and qtrs = '0' then 1 else 0 end)
            as has_assets,
        max(case when tag = 'LiabilitiesAndStockholdersEquity' and qtrs = '0'
                 then 1 else 0 end)
            as has_balance_sheet_total,
        max(case when tag in (
                     'StockholdersEquity',
                     'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest')
                 and qtrs = '0' then 1 else 0 end)
            as has_equity,
        max(case when tag in (
                     'Revenues',
                     'RevenueFromContractWithCustomerExcludingAssessedTax',
                     'RevenueFromContractWithCustomerIncludingAssessedTax')
                 and qtrs in ('1', '4') then 1 else 0 end)
            as has_revenue,
        max(case when tag in ('NetIncomeLoss', 'ProfitLoss')
                 and qtrs in ('1', '4') then 1 else 0 end)
            as has_bottom_line,
        max(case when tag = 'OperatingIncomeLoss' and qtrs in ('1', '4')
                 then 1 else 0 end)
            as has_operating_income,

        -- Fiscal 2024, the one full year every company in the scope reports.
        -- qtrs = '4' is the annual duration; qtrs = '0' is a balance at a date.
        max(case when tag in (
                     'Revenues',
                     'RevenueFromContractWithCustomerExcludingAssessedTax',
                     'RevenueFromContractWithCustomerIncludingAssessedTax')
                 and qtrs = '4' and ddate = '20241231'
                 then try_cast(value as double) end)
            as fy2024_revenue,
        max(case when tag = 'OperatingIncomeLoss'
                 and qtrs = '4' and ddate = '20241231'
                 then try_cast(value as double) end)
            as fy2024_operating_income
    from consolidated_facts
    group by cik
),

tag_profile as (
    -- Criterion 4, volume side: how much of what the company reports is
    -- expressed in the standard taxonomy and is therefore comparable.
    select
        s.cik,
        count(distinct n.tag) filter (where n.version <> n.adsh) as standard_tags,
        count(distinct n.tag) filter (where n.version =  n.adsh) as custom_tags,
        round(100.0 * count(*) filter (where n.version <> n.adsh) / count(*), 1)
            as pct_standard_facts
    from raw.num n
    join raw.sub s using (adsh)
    where s.form in ('10-K', '10-Q')
    group by s.cik
),

eligible as (
    select
        f.cik,
        f.company_name,
        f.sic_code,
        t.standard_tags,
        t.custom_tags,
        t.pct_standard_facts,
        a.fy2024_revenue,
        round(100.0 * a.fy2024_operating_income / nullif(a.fy2024_revenue, 0), 1)
            as fy2024_operating_margin_pct
    from filing_cycle f
    join account_coverage a using (cik)
    join tag_profile t using (cik)
    where f.sic_code in ('5810', '5812')                   -- criterion 1
      and a.has_assets = 1
      and a.has_balance_sheet_total = 1
      and a.has_equity = 1
      and a.has_revenue = 1
      and a.has_bottom_line = 1
      and a.has_operating_income = 1                       -- criterion 4
      and f.cik <> '1618755'                               -- criterion 5
)

select
    row_number() over (order by fy2024_revenue desc) as rank,
    lpad(cik, 10, '0') as cik,                             -- as data.sec.gov expects it
    company_name,
    round(fy2024_revenue / 1e9, 2) as fy2024_revenue_busd,
    fy2024_operating_margin_pct,
    standard_tags,
    custom_tags,
    pct_standard_facts
from eligible
order by fy2024_revenue desc
limit 10;                                                  -- criterion 6
