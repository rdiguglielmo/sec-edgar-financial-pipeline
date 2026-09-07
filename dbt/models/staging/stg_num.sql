{{
    config(
        materialized = 'incremental',
        unique_key = 'fact_natural_key',
        incremental_strategy = 'delete+insert',
    )
}}

/*
    One row per reported numeric fact. This is the model the three open
    modelling decisions land in; docs/modeling_decisions.md carries the options
    that were weighed and the numbers behind each.

    ------------------------------------------------------------------------
    Why this model is incremental, and why the strategy is not merge
    ------------------------------------------------------------------------
    It is the only expensive model in the project: 14.6 million rows carrying a
    window function, against 22,604 in the fact and under 4,000 in every
    dimension. A new quarterly archive adds roughly 3.7 million rows to raw.num
    and leaves the other 14.6 million untouched, so reprocessing all of them is
    work with a known and measured outcome.

    The batch is selected on _ingested_at rather than on the source file name.
    Both would catch a new quarter, but only _ingested_at catches the case that
    matters more: the SEC republishing a corrected archive under the same name.
    That row arrives with the same natural key and a later ingestion timestamp,
    and the write below replaces it in place.

    The strategy is delete+insert, and the reason is measured. This model holds
    138 natural keys with two rows each, 276 rows, 134 of those pairs carrying
    different values: real, distinct forward currency positions filed by Ares
    Strategic Income Fund under one reused contract identifier. Tested against
    DuckDB directly, MERGE keeps one row per key and drops the other with no
    error raised, so a merge strategy here would silently delete 138 rows on
    every incremental run, and the unique test that currently fails on 138 keys
    would start passing. A test that passes because rows were deleted is worse
    than one that fails honestly. delete+insert removes every row carrying an
    incoming key and reinserts all of them, so both survive.

    The fact table uses merge, because inside the analytical scope the same key
    is unique on all 22,604 rows: zero duplicates, measured.

    Two properties of the source make the batched window function safe, and both
    were measured rather than assumed. Zero of the 26,085 accession numbers
    appear in more than one quarterly archive, and zero natural keys span two
    archives, so has_duplicate_natural_key computed within one batch sees every
    row of every group it flags.

    A limitation worth stating: a row removed by a republished archive is not
    deleted here, because an incremental model only ever sees what arrived. That
    is what dbt run --full-refresh is for, and it rebuilds this model in about
    45 seconds.

    Rows in:  14,621,539
    Rows out: 14,619,494
    Discarded: 2,045 rows, 0.014%, all of them by the duration filter below.

    Decision 1, durations. qtrs states how many quarters a fact spans, and 88
    distinct values appear rather than the three the documentation suggests.
    Values 0 to 4 are kept: point in time, quarter, half year, nine months and
    full year. Values 5 to 124 are dropped, 2,045 rows, because a fact spanning
    up to 31 years on tags such as StockIssuedDuringPeriodSharesNewIssues is
    filer error rather than a period. None of them belongs to a company in the
    analytical scope.

    Keeping 2 and 3 keeps a double counting hazard in the table on purpose: a
    nine month year to date figure sits beside the three quarters it contains,
    so summing the value column without constraining the duration adds the same
    money twice. Dropping them would have removed it, at the cost of 5,135
    facts in the scope, and would have left nine of the ten companies with no
    interim cash flow statement at all, since only McDonald's reports the
    discrete quarter rather than the year to date figure. is_year_to_date
    exists so that every aggregate has to state which duration it means.

    Decision 2, segments. Every fact is kept, consolidated and broken down
    alike, and segments stays part of the natural key. 57.76% of facts globally
    and 50.27% within the scope carry a breakdown by business segment, equity
    component, product or geography, and a consolidated figure shares its tag,
    period, duration and unit with each of its breakdowns. Filtering to
    consolidated rows would have removed 8,445,022 facts and, in the scope, the
    entire statement of stockholders' equity plus the 57 concepts that never
    appear consolidated. is_consolidated exists for the same reason
    is_year_to_date does: any aggregate that omits it is wrong by a factor of
    roughly two, silently.

    Decision 3, duplicates on the natural key. The SEC documents num.txt as
    unique on the eight fields hashed into fact_natural_key. It is not: 138 key
    groups hold two rows each, 134 of them with different values. Both rows are
    kept and flagged. They are real, distinct forward currency contracts filed
    by one company, Ares Strategic Income Fund, that collide because the fund
    reused one contract identifier for several positions, and the two values
    differ by 3.2 million at the median. No resolution rule can recover which
    position each value belongs to, so none is invented. The unique test on
    fact_natural_key is expected to fail on 138 keys, and that failure is the
    finding. None of the 276 rows belongs to a company in the analytical scope.
*/

with source as (

    select * from {{ source('raw', 'num') }}

    {% if is_incremental() %}
    -- Only what the raw loader landed after this model was last built. The
    -- loader stamps one _ingested_at per run across every member file it
    -- loads, so a batch is always whole archives and never half of one.
    where _ingested_at > (select max(_ingested_at) from {{ this }})
    {% endif %}

),

within_documented_durations as (

    select *
    from source
    where cast(qtrs as integer) <= 4

),

typed as (

    select
        md5(concat_ws('|', adsh, tag, version, ddate, qtrs, uom, segments, coreg))
                                                    as fact_natural_key,
        md5(tag || '|' || version)                  as concept_key,

        adsh                                        as accession_number,
        tag                                         as tag_name,
        version                                     as tag_version,

        -- Period end, not filing date. 561 facts fall outside 2010 to 2027 and
        -- are flagged by a singular test rather than removed here. The raw
        -- layer holds 565; four of them sat in the discarded long tail.
        strptime(ddate, '%Y%m%d')::date             as period_end_date,
        cast(qtrs as integer)                       as period_length_qtrs,
        cast(qtrs as integer) in (2, 3)             as is_year_to_date,

        uom                                         as unit_of_measure,

        -- Empty means consolidated, not missing, so it is preserved as an empty
        -- string. Nulling it would break the natural key and would erase the
        -- distinction between "the company total" and "not stated".
        segments,
        segments = ''                               as is_consolidated,
        coreg                                       as coregistrant,
        coreg <> ''                                 as is_coregistrant_fact,

        -- 655,105 facts (4.48%) arrive with no value, of which 655,031 survive
        -- the duration filter. The expectation that a footnote would explain
        -- them does not hold: only 1,434 of the 655,105 carry one. The not_null
        -- test on this column is expected to fail on all 655,031.
        cast(nullif(value, '') as decimal(28, 4))   as value,
        nullif(footnote, '')                        as footnote,
        footnote <> ''                              as has_footnote,

        _source_file,
        _ingested_at,
        _batch_id

    from within_documented_durations

),

flagged as (

    select
        *,
        count(*) over (partition by fact_natural_key) > 1 as has_duplicate_natural_key
    from typed

)

select * from flagged
