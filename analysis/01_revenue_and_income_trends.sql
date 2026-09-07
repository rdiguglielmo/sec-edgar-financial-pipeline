-- Business question 1: how did revenue and net income evolve for each company,
-- quarter by quarter?
--
-- ---------------------------------------------------------------------------
-- Which flags this query uses, and why
-- ---------------------------------------------------------------------------
-- The fact table carries three flags because three different properties of this
-- source produce a total larger than the truth without raising an error. A
-- query that sums money has to take a position on all three, so each is stated
-- here rather than left to the reader.
--
--   is_consolidated = true        REQUIRED. A consolidated figure and each of
--                                 its segment breakdowns share the same tag,
--                                 period, duration and unit. 11,362 of the
--                                 22,604 facts in scope are breakdowns, so
--                                 omitting this roughly doubles every total.
--
--   is_latest_report = true       REQUIRED. Every 10-Q restates the prior year
--                                 comparative, so the same economic fact is
--                                 filed by several filings: 22,604 rows carry
--                                 20,764 distinct economic facts. Without this,
--                                 a quarter that appears in two filings is
--                                 counted twice.
--
--   is_year_to_date = false       REQUIRED, and expressed here as
--                                 period_length_qtrs = 1 because this question
--                                 asks for discrete quarters. A nine month year
--                                 to date figure sits in the same column as the
--                                 three quarters it contains; adding them
--                                 returns nearly double.
--
-- unit_of_measure = 'USD' is not a hazard flag but is equally required: the
-- scope also reports share counts, and adding a share to a dollar is arithmetic
-- on incompatible quantities.
--
-- ---------------------------------------------------------------------------
-- Two properties of the source this query has to work around
-- ---------------------------------------------------------------------------
-- There is no single tag for revenue. Four standard tags are in use across the
-- source and three of them inside the scope, so the metric coalesces over an
-- accepted list in a stated order and reports which tag each figure came from.
-- Hiding that would make the number unauditable.
--
-- The same applies below the income statement: NetIncomeLoss is the result
-- attributable to the parent and ProfitLoss includes noncontrolling interests.
-- Bloomin' Brands and Cheesecake Factory file both for the same period, and the
-- two differ. NetIncomeLoss is preferred because it is the figure per share
-- calculations use, and the tag used is reported.
--
-- The fourth quarter is never filed as a discrete quarter, so Q4 is derived as
-- the full year minus the first three, and only when all three are present for
-- both metrics: a half derived row would be worse than a missing one. Derived
-- rows are marked in is_derived_quarter so no reader mistakes them for filed
-- figures. Ten of the 73 rows returned are derived.
--
-- Coverage is not square, and that is a property of the source rather than of
-- this query. A filing carries the prior year comparative, so 2024 and 2025
-- return all ten companies while 2023 returns only Bloomin' Brands, whose
-- filings reach back further, and returns revenue without a matching net income.
-- Nothing is filled in: an absent comparative stays null.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/01_revenue_and_income_trends.sql

with metric_tags as (
    -- The accepted tags per metric, with the preference order applied when a
    -- company files more than one for the same period.
    select * from (values
        ('revenue',      'RevenueFromContractWithCustomerExcludingAssessedTax', 1),
        ('revenue',      'RevenueFromContractWithCustomerIncludingAssessedTax', 2),
        ('revenue',      'Revenues',                                           3),
        ('revenue',      'RevenuesNetOfInterestExpense',                       4),
        ('net_income',   'NetIncomeLoss',                                      1),
        ('net_income',   'ProfitLoss',                                         2),
        ('operating',    'OperatingIncomeLoss',                                1)
    ) as t(metric, tag_name, tag_preference)
),

reported as (
    select
        c.company_name,
        c.cik,
        m.metric,
        m.tag_name,
        m.tag_preference,
        f.period_end_key                    as period_end_date,
        d.calendar_year,
        d.calendar_quarter,
        f.period_length_qtrs,
        f.value
    from marts.fct_financial_facts f
    join marts.dim_company  c on c.company_key  = f.company_key
    join marts.dim_account  a on a.account_key  = f.account_key
    join marts.dim_date     d on d.date_key     = f.period_end_key
    join metric_tags        m on m.tag_name     = a.tag_name
    where f.is_consolidated                       -- see the flag notes above
      and f.is_latest_report
      and f.unit_of_measure = 'USD'
      and f.period_length_qtrs in (1, 4)          -- discrete quarter or full year
      and f.value is not null
),

-- One figure per company, metric and period, taking the preferred tag when a
-- company files more than one.
resolved as (
    select
        company_name, cik, metric, period_end_date, calendar_year,
        calendar_quarter, period_length_qtrs, value, tag_name
    from reported
    qualify row_number() over (
        partition by cik, metric, period_end_date, period_length_qtrs
        order by tag_preference
    ) = 1
),

quarterly as (
    select
        company_name, cik, calendar_year, calendar_quarter, period_end_date,
        max(value) filter (where metric = 'revenue')    as revenue,
        max(value) filter (where metric = 'net_income') as net_income,
        max(tag_name) filter (where metric = 'revenue')    as revenue_tag,
        max(tag_name) filter (where metric = 'net_income') as net_income_tag
    from resolved
    where period_length_qtrs = 1
    group by 1, 2, 3, 4, 5
),

annual as (
    select
        cik, calendar_year,
        max(value) filter (where metric = 'revenue')    as revenue,
        max(value) filter (where metric = 'net_income') as net_income
    from resolved
    where period_length_qtrs = 4
    group by 1, 2
),

-- Q4 is not filed on its own. It is the full year less the three quarters that
-- were, and only for a year where all three are present.
derived_q4 as (
    select
        q.company_name,
        q.cik,
        q.calendar_year,
        4                                       as calendar_quarter,
        make_date(q.calendar_year, 12, 31)      as period_end_date,
        a.revenue    - sum(q.revenue)           as revenue,
        a.net_income - sum(q.net_income)        as net_income,
        'derived: full year less Q1 to Q3'      as revenue_tag,
        'derived: full year less Q1 to Q3'      as net_income_tag
    from quarterly q
    join annual a on a.cik = q.cik and a.calendar_year = q.calendar_year
    where q.calendar_quarter in (1, 2, 3)
    group by q.company_name, q.cik, q.calendar_year, a.revenue, a.net_income
    having count(*) = 3
       and count(q.revenue) = 3
       and count(q.net_income) = 3
),

combined as (
    select *, false as is_derived_quarter from quarterly
    where calendar_quarter in (1, 2, 3)
    union all
    select
        company_name, cik, calendar_year, calendar_quarter, period_end_date,
        revenue, net_income, revenue_tag, net_income_tag, true
    from derived_q4
),

with_trend as (
    select
        *,
        lag(revenue)    over (partition by cik order by period_end_date) as prior_quarter_revenue,
        lag(revenue, 4) over (partition by cik order by period_end_date) as year_ago_revenue,
        lag(net_income, 4) over (partition by cik order by period_end_date) as year_ago_net_income
    from combined
)

select
    company_name,
    calendar_year                                           as year,
    'Q' || calendar_quarter                                 as quarter,
    is_derived_quarter,
    round(revenue / 1e6, 1)                                 as revenue_musd,
    round(net_income / 1e6, 1)                              as net_income_musd,
    round(100.0 * net_income / nullif(revenue, 0), 1)       as net_margin_pct,
    round(100.0 * (revenue - prior_quarter_revenue)
          / nullif(abs(prior_quarter_revenue), 0), 1)       as revenue_qoq_pct,
    round(100.0 * (revenue - year_ago_revenue)
          / nullif(abs(year_ago_revenue), 0), 1)            as revenue_yoy_pct,
    round(100.0 * (net_income - year_ago_net_income)
          / nullif(abs(year_ago_net_income), 0), 1)         as net_income_yoy_pct,
    revenue_tag,
    net_income_tag
from with_trend
order by company_name, period_end_date;
