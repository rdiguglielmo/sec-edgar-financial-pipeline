/*
    One row per filing made by a company in the scope.

    Rows in:  26,085
    Rows out: 40
    Discarded: 26,045 filings belonging to companies outside the scope. No other
    filter is applied: no form type filter, no date filter, no amendment filter.

    That is worth stating because it is easy to assume otherwise. The scope
    criteria required exactly one 10-K and three 10-Q per company, so the forty
    filings that survive the company filter happen to be ten 10-K and thirty
    10-Q, all of them detailed, none an amendment and none with more than one
    registrant. Those are measured properties of the result, not conditions
    imposed here, and the tests in schema.yml assert them so that a future
    quarter which breaks the pattern is reported rather than silently absorbed.

    The company is reached through cik rather than through a foreign key to
    dim_company. A dimension pointing at another dimension is a snowflake, and
    the fact already carries both keys, so the join it would serve does not
    exist. cik is kept for tracing a row back to the source.

    accepted_at precedes filed_date on 2,056 filings of the full data set,
    because EDGAR dates a submission accepted after the daily cutoff to the next
    business day. No test asserts an ordering between them; the reasoning is in
    stg_sub.sql.
*/

with scope as (

    select cik from {{ ref('scope_companies') }}

),

scope_filings as (

    select *
    from {{ ref('stg_sub') }}
    where cik in (select cik from scope)

)

select
    md5(accession_number)               as filing_key,
    accession_number,
    cik,

    form_type,
    is_amendment,

    fiscal_year,
    fiscal_period,
    period_end_date,
    filed_date,
    accepted_at,

    is_detailed,
    is_previous_report,

    registrant_count,
    is_multi_registrant

from scope_filings
