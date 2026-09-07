/*
    One row per filing.

    Rows in:  26,085
    Rows out: 26,085
    Discarded: none. This model applies no row filter of any kind.

    The analytical scope of the project is ten companies, but the scope is a
    property of the analysis, not of the source. Restricting it here would make
    every data quality test measure a 0.15% slice of the filings and would
    remove the base that business question 4, custom versus standard tagging,
    is asked about. The scope filter belongs to the marts.

    Columns not carried forward, all of them postal detail no model reads:
    zipba, bas1, bas2, baph, countryma, stprma, cityma, zipma, mas1, mas2.
    They remain available in raw.sub.

    Typing notes, each measured against the loaded data:

    - cik arrives without leading zeros, between 4 and 7 characters wide, and
      not one of the 26,085 filings has a leading zero. It is padded to 10 here
      because that is the form the SEC's own submissions API expects and the
      form src/config.py stores the scope in. Left unpadded, a join against
      SCOPE_CIKS silently returns nothing.
    - fye keeps its padding at the source, 4,798 filings start in a zero, so it
      stays a 4 character string. Cast to a number it would read 0630 as 630.
    - accepted precedes filed on 2,056 filings (7.88%). That is not corruption:
      EDGAR assigns the next business day to submissions accepted after the
      daily cutoff. No test asserts accepted <= filed.
*/

with source as (

    select * from {{ source('raw', 'sub') }}

),

typed as (

    select
        adsh                                                as accession_number,
        lpad(cik, 10, '0')                                  as cik,
        name                                                as company_name,
        nullif(sic, '')                                     as sic_code,

        nullif(cityba, '')                                  as business_city,
        nullif(stprba, '')                                  as business_state,
        nullif(countryba, '')                               as business_country,
        nullif(stprinc, '')                                 as incorporation_state,
        nullif(countryinc, '')                              as incorporation_country,
        nullif(ein, '')                                     as ein,

        nullif(former, '')                                  as former_company_name,
        strptime(nullif(changed, ''), '%Y%m%d')::date       as name_changed_date,

        nullif(afs, '')                                     as filer_status,
        wksi = '1'                                          as is_well_known_seasoned_issuer,
        nullif(fye, '')                                     as fiscal_year_end_mmdd,

        form                                                as form_type,
        form like '%/A'                                     as is_amendment,
        strptime(nullif(period, ''), '%Y%m%d')::date        as period_end_date,
        cast(nullif(fy, '') as integer)                     as fiscal_year,
        nullif(fp, '')                                      as fiscal_period,
        strptime(filed, '%Y%m%d')::date                     as filed_date,
        accepted::timestamp                                 as accepted_at,

        prevrpt = '1'                                       as is_previous_report,
        detail = '1'                                        as is_detailed,
        nullif(instance, '')                                as instance_document,

        cast(nciks as integer)                              as registrant_count,
        cast(nciks as integer) > 1                          as is_multi_registrant,
        nullif(aciks, '')                                   as additional_ciks,

        _source_file,
        _ingested_at,
        _batch_id

    from source

)

select * from typed
