/*
    The fact holds exactly the staging rows that belong to the scope: no row
    added, no row lost.

    Expected to pass, returning no rows. Both counts are 22,604 today.

    The companion to assert_fact_does_not_fan_out_over_dimensions. That one
    checks the fact against the dimensions; this one checks it against its
    source. Between them they close both directions of the same requirement.

    Losing rows is the quieter of the two failures. fct_financial_facts joins to
    the chosen presentation line, and an inner join there would drop any fact
    the source never presented on a statement. There are none today, which is
    why the model uses left joins, and this test is what would report it if a
    later quarter arrived with one.
*/

with staging_rows_in_scope as (

    select count(*) as row_count
    from {{ ref('stg_num') }}
    where accession_number in (
        select accession_number from {{ ref('dim_filing') }}
    )

),

fact_rows as (

    select count(*) as row_count
    from {{ ref('fct_financial_facts') }}

)

select
    s.row_count                 as staging_rows_in_scope,
    f.row_count                 as fact_rows,
    f.row_count - s.row_count   as difference
from staging_rows_in_scope s
cross join fact_rows f
where s.row_count <> f.row_count
