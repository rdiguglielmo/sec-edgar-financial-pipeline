-- Business question 3: how did the debt to equity relationship evolve by
-- industry code (SIC), quarter by quarter?
--
-- ---------------------------------------------------------------------------
-- Which flags this query uses, and why
-- ---------------------------------------------------------------------------
--   is_consolidated = true        REQUIRED. Balance sheet totals are reported
--                                 both consolidated and broken down by equity
--                                 component: EquityComponents=CommonStock and
--                                 EquityComponents=RetainedEarnings are the two
--                                 segment strings all ten companies use. Adding
--                                 them to the total counts the same capital
--                                 several times.
--
--   is_latest_report = true       REQUIRED. Each balance sheet date is filed
--                                 again as the comparative of a later filing.
--                                 The value can differ between the two, which
--                                 is what is_restated marks, so the flag also
--                                 picks the corrected figure over the original.
--
--   is_year_to_date = false       Not applicable, and that is the point of
--                                 saying so. These are balances at a date, not
--                                 flows over a period: period_length_qtrs = 0,
--                                 for which is_year_to_date is always false. A
--                                 balance has no duration to double count.
--
-- ---------------------------------------------------------------------------
-- Two measured properties this query has to answer for
-- ---------------------------------------------------------------------------
-- Liabilities is reported by nine of the ten companies. McDonald's files only
-- the balance sheet total, so total liabilities are derived from the accounting
-- identity: assets equal liabilities plus equity. The derivation is marked in
-- liabilities_source so a reader never has to guess which figure was filed.
--
-- Three of the ten carry negative book equity: Yum! Brands, McDonald's and
-- Papa John's have bought back more stock than they have retained earnings. A
-- debt to equity ratio on a negative denominator is not a low ratio, it is a
-- meaningless one, and averaging it into a sector figure would corrupt the
-- sector figure too. So the ratio is returned as null for those companies,
-- flagged in has_negative_equity, and liabilities over assets is reported
-- beside it because that ratio stays defined whatever equity does.
--
-- On "by sector": the scope is one industry that the SEC's own classification
-- splits across two codes, 5812 and 5810, with the filer choosing which one it
-- reports. Grouping by the raw column would present that choice as an industry
-- difference. Both groupings are returned, the codes and the industry, so the
-- artifact is visible rather than averaged away. See docs/scope.md.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/03_leverage_by_sector.sql

create or replace temp view balance_positions as

with balance_facts as (
    select
        c.company_name,
        c.cik,
        c.sic_code,
        c.industry_name,
        f.period_end_key    as period_end_date,
        d.quarter_label,
        a.tag_name,
        f.value
    from marts.fct_financial_facts f
    join marts.dim_company c on c.company_key = f.company_key
    join marts.dim_account a on a.account_key = f.account_key
    join marts.dim_date    d on d.date_key    = f.period_end_key
    where f.is_consolidated                   -- see the flag notes above
      and f.is_latest_report
      and f.unit_of_measure = 'USD'
      and f.period_length_qtrs = 0            -- a balance at a date
      and f.value is not null
),

pivoted as (
    select
        company_name, cik, sic_code, industry_name, period_end_date, quarter_label,
        max(value) filter (where tag_name = 'Assets')                       as assets,
        max(value) filter (where tag_name = 'Liabilities')                  as reported_liabilities,
        max(value) filter (where tag_name = 'LiabilitiesAndStockholdersEquity')
                                                                            as balance_sheet_total,
        max(value) filter (where tag_name = 'StockholdersEquity')           as parent_equity,
        max(value) filter (where tag_name =
            'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest')
                                                                            as total_equity_reported
    from balance_facts
    group by 1, 2, 3, 4, 5, 6
)

select
    company_name,
    cik,
    sic_code,
    industry_name,
    period_end_date,
    quarter_label,
    assets,

    -- Total equity including any noncontrolling interest, which is the term the
    -- accounting identity uses. Seven of the ten file it directly; for the
    -- other three the parent figure is the whole of equity.
    coalesce(total_equity_reported, parent_equity)                  as total_equity,
    parent_equity,

    coalesce(
        reported_liabilities,
        balance_sheet_total - coalesce(total_equity_reported, parent_equity)
    )                                                               as total_liabilities,

    case
        when reported_liabilities is not null then 'reported'
        when balance_sheet_total is not null   then 'derived from the balance sheet identity'
    end                                                             as liabilities_source,

    coalesce(total_equity_reported, parent_equity) <= 0             as has_negative_equity

from pivoted;

-- ---------------------------------------------------------------------------
-- One row per company and balance sheet date
-- ---------------------------------------------------------------------------
select
    company_name,
    sic_code,
    quarter_label,
    round(assets / 1e9, 2)                                          as assets_busd,
    round(total_liabilities / 1e9, 2)                               as liabilities_busd,
    round(total_equity / 1e9, 2)                                    as equity_busd,
    case when has_negative_equity then null
         else round(total_liabilities / nullif(total_equity, 0), 2)
    end                                                             as liabilities_to_equity,
    round(100.0 * total_liabilities / nullif(assets, 0), 1)         as liabilities_to_assets_pct,
    has_negative_equity,
    liabilities_source
from balance_positions
where assets is not null
order by period_end_date desc, liabilities_to_assets_pct desc;

-- ---------------------------------------------------------------------------
-- The same by industry code and by industry, which is the question as asked
-- ---------------------------------------------------------------------------
-- Two aggregates, because the two answer different things. Liabilities over
-- assets is summed across companies: it is defined for every company and a sum
-- weights each by size, which is what a sector figure should do. The debt to
-- equity column is a median over the companies where equity is positive,
-- because summing a negative denominator into a sector total would let one
-- company's buyback programme invert the sign of the whole industry.
select
    coalesce(sic_code, 'both codes')                                as grouping_key,
    coalesce(industry_name, 'Eating and drinking places, both codes') as grouping_label,
    quarter_label,
    count(*)                                                        as companies,
    count(*) filter (where has_negative_equity)                     as companies_with_negative_equity,
    round(100.0 * sum(total_liabilities) / nullif(sum(assets), 0), 1)
                                                                    as liabilities_to_assets_pct,
    round(median(total_liabilities / nullif(total_equity, 0))
          filter (where not has_negative_equity), 2)                as median_liabilities_to_equity
from balance_positions
where assets is not null
group by grouping sets ((sic_code, industry_name, quarter_label), (quarter_label))
order by quarter_label desc, grouping_key;
