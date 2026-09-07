-- Business question 2: which companies improved their operating margin year
-- over year, and which let it deteriorate?
--
-- ---------------------------------------------------------------------------
-- Which flags this query uses, and why
-- ---------------------------------------------------------------------------
--   is_consolidated = true        REQUIRED. A margin is a ratio of two company
--                                 level figures. Segment breakdowns repeat the
--                                 same tag and period, so including them would
--                                 put a numerator and a denominator built from
--                                 different populations on the same line.
--
--   is_latest_report = true       REQUIRED. Each fiscal year is reported by
--                                 more than one filing, since a 10-K carries
--                                 the two prior years as comparatives. Without
--                                 this flag a year returns several figures and
--                                 max() would quietly pick one.
--
--   is_year_to_date = false       Satisfied by construction, not by chance.
--                                 This query reads period_length_qtrs = 4, the
--                                 full year, and is_year_to_date is only true
--                                 for the half year and nine month durations,
--                                 so no year to date row can enter. Stating it
--                                 matters because the same query written
--                                 against quarters would need the flag
--                                 explicitly.
--
-- ---------------------------------------------------------------------------
-- Why operating margin and not gross margin
-- ---------------------------------------------------------------------------
-- Cost of revenue is reported by 46.13% of the companies in the source and by
-- 12 of the 42 in this industry, so gross margin cannot be computed for a set
-- of comparable companies. Operating income is reported by all ten. This is the
-- most granular margin that generalises here, and the constraint is measured
-- rather than assumed; see docs/data_quality.md.
--
-- The industry was chosen because its margin spread has a structural cause: a
-- franchisor collects royalties without carrying the cost of operating the
-- restaurants, while a company operator carries both. The spread this query
-- returns is that difference, not noise.
--
-- Three fiscal years are available, 2022 to 2024, which gives two year over
-- year comparisons. FY2025 is not here: the 10-K reporting it was filed in
-- February 2026 and lands in the 2026q1 archive, which config.QUARTERS does not
-- yet cover. src/incremental.py has already indexed those ten filings.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/02_margin_evolution_yoy.sql

with revenue_tags as (
    -- No single tag carries revenue. The accepted list with a preference order,
    -- and the tag actually used is reported so the figure can be audited.
    select * from (values
        ('RevenueFromContractWithCustomerExcludingAssessedTax', 1),
        ('RevenueFromContractWithCustomerIncludingAssessedTax', 2),
        ('Revenues',                                           3),
        ('RevenuesNetOfInterestExpense',                       4)
    ) as t(tag_name, tag_preference)
),

annual_facts as (
    select
        c.company_name,
        c.cik,
        c.sic_code,
        c.industry_name,
        d.calendar_year                     as fiscal_year,
        a.tag_name,
        f.value
    from marts.fct_financial_facts f
    join marts.dim_company c on c.company_key = f.company_key
    join marts.dim_account a on a.account_key = f.account_key
    join marts.dim_date    d on d.date_key    = f.period_end_key
    where f.is_consolidated                   -- see the flag notes above
      and f.is_latest_report
      and f.unit_of_measure = 'USD'
      and f.period_length_qtrs = 4            -- full year; excludes year to date by construction
      and f.value is not null
),

revenue as (
    select company_name, cik, sic_code, industry_name, fiscal_year, value, tag_name
    from annual_facts
    join revenue_tags using (tag_name)
    qualify row_number() over (
        partition by cik, fiscal_year order by tag_preference
    ) = 1
),

operating_income as (
    select cik, fiscal_year, value
    from annual_facts
    where tag_name = 'OperatingIncomeLoss'
),

margins as (
    select
        r.company_name,
        r.sic_code,
        r.industry_name,
        r.fiscal_year,
        r.value                                             as revenue,
        o.value                                             as operating_income,
        100.0 * o.value / nullif(r.value, 0)                as operating_margin_pct,
        r.tag_name                                          as revenue_tag,
        lag(100.0 * o.value / nullif(r.value, 0)) over (
            partition by r.cik order by r.fiscal_year
        )                                                   as prior_year_margin_pct
    from revenue r
    join operating_income o on o.cik = r.cik and o.fiscal_year = r.fiscal_year
)

select
    company_name,
    sic_code,
    industry_name,
    fiscal_year,
    round(revenue / 1e9, 2)                                 as revenue_busd,
    round(operating_income / 1e9, 2)                        as operating_income_busd,
    round(operating_margin_pct, 1)                          as operating_margin_pct,
    round(prior_year_margin_pct, 1)                         as prior_year_margin_pct,
    round(operating_margin_pct - prior_year_margin_pct, 1)  as margin_change_points,
    case
        when prior_year_margin_pct is null then 'no prior year in scope'
        when operating_margin_pct - prior_year_margin_pct >  0.5 then 'improved'
        when operating_margin_pct - prior_year_margin_pct < -0.5 then 'deteriorated'
        else 'flat within half a point'
    end                                                     as direction,
    revenue_tag
from margins
order by fiscal_year desc, operating_margin_pct desc;
