/*
    One row per filing as indexed under one company by the SEC submissions API.

    Rows in:  867
    Rows out: 867
    Discarded: none. src/incremental.py lands every form the endpoint returns,
    including the ownership and prospectus forms this project does not model, so
    that the count of what a company files is measurable rather than assumed.

    This model is the one place in the staging layer whose coverage is the
    analytical scope rather than the whole source, and that is a property of the
    endpoint, not a filter written here: https://data.sec.gov/submissions/ is
    queried one company at a time, and the ten companies queried are the ten in
    the scope seed.

    What this is for
    ----------------
    The quarterly archives are a bulk snapshot published about a quarter behind.
    This index is what the pipeline knows about filings made since. It carries
    metadata only: the API publishes the accession number, the form and the
    dates, never the reported figures, so a filing indexed here has no facts
    until the archive covering its quarter has been downloaded and loaded.
    quarterly_archive names that archive, and is_in_loaded_archives says whether
    the filing is already in the bulk load.

    Measured on the first incremental run, 2026-08-06:

        867 filings indexed since the bulk load
        857 new, 10 already present in raw.sub
         34 of them 10-K or 10-Q, the forms this pipeline models
        543 Form 4, insider transactions, the largest single form

    The ten already present are the boundary re-reads the watermark margin is
    designed to allow. sub.txt rounds the acceptance timestamp to the nearest
    minute, which for three of the ten companies places it after the true time,
    so the watermark is pulled back 60 seconds. Re-reading a filing costs
    nothing because the write is an upsert; skipping one cannot be recovered.
*/

with source as (

    select * from {{ source('raw', 'filing_index') }}

),

loaded_filings as (

    -- The filings the quarterly archives already carry, used to separate a
    -- boundary re-read from a genuinely new filing.
    select accession_number from {{ ref('stg_sub') }}

),

typed as (

    select
        md5(cik || '|' || accession_number)         as filing_index_key,

        cik,
        accession_number,
        form_type,
        form_type like '%/A'                        as is_amendment,
        form_type in ('10-K', '10-Q')               as is_financial_statement_form,

        strptime(filing_date, '%Y-%m-%d')::date     as filing_date,

        -- Naive UTC to the second, as the API publishes it. raw.sub records the
        -- same event in US Eastern rounded to the minute, so the two columns
        -- disagree by five hours and up to thirty seconds on the same filing.
        acceptance_datetime::timestamp              as accepted_at,

        strptime(nullif(report_date, ''), '%Y-%m-%d')::date as report_date,

        -- The quarterly archive that will carry this filing's figures, derived
        -- from the calendar quarter it was filed in.
        strftime(strptime(filing_date, '%Y-%m-%d'), '%Y')
            || 'q'
            || quarter(strptime(filing_date, '%Y-%m-%d'))::varchar
                                                    as quarterly_archive,

        nullif(items, '')                           as report_items,
        nullif(act, '')                             as securities_act,
        nullif(file_number, '')                     as file_number,
        nullif(core_type, '')                       as core_type,
        nullif(primary_document, '')                as primary_document,
        nullif(primary_doc_description, '')         as primary_document_description,

        cast(file_size as bigint)                   as document_bytes,
        is_xbrl = '1'                               as is_xbrl,
        is_inline_xbrl = '1'                        as is_inline_xbrl,
        is_xbrl_numeric = '1'                       as is_xbrl_numeric,

        _source_file,
        _ingested_at,
        _batch_id

    from source

)

select
    t.*,
    l.accession_number is not null                  as is_in_loaded_archives
from typed t
left join loaded_filings l on l.accession_number = t.accession_number
