/*
    A fact reported in the 2025 archives cannot cover a period ending in 1011
    or in 2050.

    Expected to fail on 561 facts out of 14,619,494, that is 0.0038%, spread
    over 106 distinct date values and 264 filings. The extremes are 1011-12-31
    and 2050-03-31, which are filer typos.

    The bounds are wider than the data needs on purpose. Comparatives inside a
    10-K reach back three years and forward looking disclosures reach a couple
    of years ahead, so 2010 to 2027 flags nonsense without flagging legitimate
    history. The rows are not removed in the model: 561 typos are worth less
    than a silent filter over 14.6 million facts.
*/

{{ config(meta = {'expected_failures': 561}) }}

select
    accession_number,
    tag_name,
    period_end_date,
    period_length_qtrs,
    unit_of_measure,
    value
from {{ ref('stg_num') }}
where period_end_date < date '2010-01-01'
   or period_end_date > date '2027-12-31'
