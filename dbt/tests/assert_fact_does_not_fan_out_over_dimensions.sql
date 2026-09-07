/*
    Joining the fact to every dimension must return the fact, not a multiple of
    it.

    Expected to pass, returning no rows.

    This is the guarantee the whole marts layer is built around, so it is
    asserted rather than assumed. A dimension with a finer grain than the fact
    silently multiplies rows, and the result of that is not an error message: it
    is a total two or three times larger than the truth that looks entirely
    plausible. The measured case in this project is the presentation line:
    22,604 facts match 28,103 lines, so joining fct_financial_facts to stg_pre
    instead of to dim_statement inflates every figure by 24.3%.

    fct_financial_facts avoids that by resolving the line before the fact is
    built, in the model itself, and this test is what proves the resolution
    worked. It fails the moment a dimension gains a duplicate key, which is the
    other way the same defect arrives.
*/

with fact_rows as (

    select count(*) as row_count
    from {{ ref('fct_financial_facts') }}

),

rows_after_joining_every_dimension as (

    select count(*) as row_count
    from {{ ref('fct_financial_facts') }} f
    join {{ ref('dim_company') }}   c on c.company_key   = f.company_key
    join {{ ref('dim_filing') }}    g on g.filing_key    = f.filing_key
    join {{ ref('dim_account') }}   a on a.account_key   = f.account_key
    join {{ ref('dim_statement') }} s on s.statement_key = f.statement_key
    join {{ ref('dim_date') }}      d on d.date_key      = f.period_end_key

)

select
    f.row_count             as fact_rows,
    j.row_count             as rows_after_joining,
    j.row_count - f.row_count as difference
from fact_rows f
cross join rows_after_joining_every_dimension j
where j.row_count <> f.row_count
