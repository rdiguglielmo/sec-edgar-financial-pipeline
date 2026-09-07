/*
    One row per presentation line: where a concept appears inside a filing's
    rendered statements, and under what label.

    Rows in:  2,965,835
    Rows out: 2,965,835
    Discarded: none.

    The declared key (adsh, report, line) holds exactly: zero duplicates across
    all four archives.

    statement_code is deliberately not nulled when it is empty. The SEC
    documents seven codes and an eighth value appears in the data, the empty
    string, on 257 lines across 8 filings. Nulling it would hide those rows
    from the accepted_values test, because dbt's accepted_values ignores nulls.
    The empty string is a value here, not an absence, and the test is meant to
    find it.

    rfile is H on all 2,965,835 rows. The documented alternative, X for XML,
    does not occur in 2025.

    A concept can appear on several presentation lines of the same filing:
    141,574 groups appear on two lines, 57,030 on three, 13,921 on more, and
    158,185 of them span more than one statement. Any join from a fact to this
    table fans out unless it picks a line, which is a marts problem and is
    recorded as such.
*/

with source as (

    select * from {{ source('raw', 'pre') }}

),

typed as (

    select
        md5(adsh || '|' || report || '|' || line)   as presentation_key,
        adsh                                        as accession_number,
        cast(report as integer)                     as report_number,
        cast(line as integer)                       as line_number,

        stmt                                        as statement_code,
        inpth = '1'                                 as is_parenthetical,
        rfile                                       as render_file_type,

        md5(tag || '|' || version)                  as concept_key,
        tag                                         as tag_name,
        version                                     as tag_version,

        nullif(plabel, '')                          as presentation_label,
        negating = '1'                              as is_negating,

        _source_file,
        _ingested_at,
        _batch_id

    from source

)

select * from typed
