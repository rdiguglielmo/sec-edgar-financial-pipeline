/*
    One row per calendar day.

    Rows out: 3,653, from 2016-01-01 to 2025-12-31.
    Discarded: nothing. This dimension is generated rather than read.

    The bounds are derived, not typed in. The scope needs 2016-10-31, the oldest
    period end any of its facts reports, through 2025-11-10, the day the last
    10-Q was filed, and the model rounds that outward to whole calendar years.
    Hard coding the years would work today and break silently the first time a
    new archive carries an older comparative: the fact would point at a date the
    dimension does not hold, and only the relationships test would say so.

    Why every day and not only the 51 dates in use
    ----------------------------------------------
    A date dimension with gaps cannot answer "what happened in the quarter with
    no filing", and Power BI's time intelligence requires a contiguous calendar
    to mark a table as a date table at all. 3,653 rows cost nothing.

    Calendar and fiscal are the same thing here
    -------------------------------------------
    Every company in the scope has a December fiscal year end, which is
    criterion 3 of the selection and the reason quarters line up across
    companies without adjustment. So no fiscal_year or fiscal_quarter column is
    added: it would duplicate the calendar one and would quietly become wrong
    the day the scope admits a company with a June year end. dim_company carries
    fiscal_year_end_mmdd, so the assumption is checkable rather than assumed.
*/

with observed_dates as (

    select period_end_date as observed_date
    from {{ ref('stg_num') }}
    where accession_number in (select accession_number from {{ ref('dim_filing') }})

    union all

    select period_end_date from {{ ref('dim_filing') }}

    union all

    select filed_date from {{ ref('dim_filing') }}

),

span as (

    select
        date_trunc('year', min(observed_date))::date                         as first_date,
        (date_trunc('year', max(observed_date)) + interval '1 year'
             - interval '1 day')::date                                       as last_date
    from observed_dates
    where observed_date is not null

),

calendar as (

    select unnest(generate_series(first_date, last_date, interval '1 day'))::date as date_key
    from span

)

select
    date_key,

    year(date_key)                                          as calendar_year,
    quarter(date_key)                                       as calendar_quarter,
    month(date_key)                                         as calendar_month,
    monthname(date_key)                                     as month_name,
    day(date_key)                                           as day_of_month,

    year(date_key) || ' Q' || quarter(date_key)             as quarter_label,

    date_key = last_day(date_key)                           as is_month_end,
    date_key = last_day(date_trunc('quarter', date_key)::date
                        + interval '2 months')              as is_quarter_end,
    date_key = make_date(year(date_key), 12, 31)            as is_year_end

from calendar
