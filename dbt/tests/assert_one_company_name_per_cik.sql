/*
    A company identifier should name one company.

    Expected to fail on 172 of the 7,151 companies, 2.41%, with at most three
    names for one identifier. The changes are real corporate events rather than
    typos: SUNPOWER INC. to COMPLETE SOLARIA, INC., UNITI GROUP INC. to
    WINDSTREAM PARENT, INC.

    This is the evidence for the dim_company decision. At 2.41% a type 2 slowly
    changing dimension is not justified for this project; the last known name,
    with the change documented, is. The test stays because that rule has to be
    stated somewhere a reader can check, and because a jump in this number means
    the naming rule needs revisiting.
*/

{{ config(meta = {'expected_failures': 172}) }}

select
    cik,
    count(distinct company_name)                    as name_count,
    string_agg(distinct company_name, ' | ')        as names
from {{ ref('stg_sub') }}
group by cik
having count(distinct company_name) > 1
