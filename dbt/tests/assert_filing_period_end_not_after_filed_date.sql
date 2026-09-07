/*
    A filing cannot report a period that ends after the day it was filed.

    Expected to fail on 2 filings out of 26,085.

    The related check that is deliberately not written is accepted_at against
    filed_date. 2,056 filings (7.88%) carry an acceptance timestamp on an
    earlier calendar day than their filing date, and that is EDGAR working as
    designed: a submission accepted after the daily cutoff is dated the next
    business day. Asserting it would produce 2,056 failures that mean nothing,
    which is how a test layer loses its credibility.
*/

{{ config(meta = {'expected_failures': 2}) }}

select
    accession_number,
    cik,
    company_name,
    form_type,
    period_end_date,
    filed_date
from {{ ref('stg_sub') }}
where period_end_date > filed_date
