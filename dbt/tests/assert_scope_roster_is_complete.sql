/*
    Every company named in the scope seed reaches the marts, with the complete
    filing cycle the selection criteria promised.

    Expected to pass, returning no rows. Ten companies, four filings each.

    The scope is the one thing in this project that is declared rather than
    derived, so it is also the one thing that can be wrong without anything
    breaking. A cik typed with a digit missing, or padded to nine digits instead
    of ten, joins to nothing: dim_company loses a company, the fact loses its
    facts, and every chart still renders. Nine restaurant chains look exactly as
    convincing as ten.

    So the test asserts three things at once, in both directions:

      - every cik in scope_companies produced a row in dim_company
      - every row in dim_company traces back to a cik in scope_companies
      - each of them filed the one 10-K and three 10-Q that criterion 2 of
        docs/scope.md required, which is what makes the annual cycle complete

    A failure on the filing count is the interesting case. It does not mean the
    roster is wrong: it means a company's filing history changed under the
    scope, and the selection has to be re-run rather than patched.
*/

with roster as (

    select cik, company_label from {{ ref('scope_companies') }}

),

dimension as (

    select cik, company_name from {{ ref('dim_company') }}

),

filing_counts as (

    select
        cik,
        count(*)                                        as filing_count,
        count(*) filter (where form_type = '10-K')      as annual_reports,
        count(*) filter (where form_type = '10-Q')      as quarterly_reports
    from {{ ref('dim_filing') }}
    group by cik

)

select
    coalesce(r.cik, d.cik)              as cik,
    r.company_label,
    d.company_name,
    coalesce(f.filing_count, 0)         as filing_count,
    coalesce(f.annual_reports, 0)       as annual_reports,
    coalesce(f.quarterly_reports, 0)    as quarterly_reports
from roster r
full outer join dimension d on d.cik = r.cik
left join filing_counts f on f.cik = coalesce(r.cik, d.cik)
where r.cik is null
   or d.cik is null
   or coalesce(f.annual_reports, 0) <> 1
   or coalesce(f.quarterly_reports, 0) <> 3
