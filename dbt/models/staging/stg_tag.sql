/*
    One row per accounting concept.

    Rows in:  348,770
    Rows out: 329,861
    Discarded: 18,909 duplicate copies of a concept, 5.42% of the input.

    This is the only staging model that removes rows, and the reason is the
    shape of the source rather than a quality problem. tag.txt is a catalogue
    shipped inside every quarterly archive, so a concept used in more than one
    quarter arrives once per archive. The declared key, (tag, version), is
    unique within an archive and repeated across them.

    Deduplicating is lossless here, and that was measured rather than assumed:
    zero of the 329,861 concepts disagree with themselves on any attribute
    across quarters, including tlabel and doc. The row kept is the one from the
    most recent archive, so a future relabelling would surface as the current
    definition rather than as an arbitrary one.

    The custom flag and the version namespace agree completely: all 31,297 rows
    flagged custom = 0 carry a standard taxonomy in version, and none of the
    317,473 flagged custom = 1 do. is_custom_tag can therefore be read straight
    off the flag instead of parsing the namespace.

    abstract is 0 on all 348,770 rows. The column is kept because it is part of
    the documented source, but it carries no information in this data.
*/

with source as (

    select * from {{ source('raw', 'tag') }}

),

deduplicated as (

    select *
    from source
    qualify row_number() over (
        partition by tag, version
        order by _source_file desc
    ) = 1

),

typed as (

    select
        md5(tag || '|' || version)      as concept_key,
        tag                             as tag_name,
        version                         as tag_version,

        custom = '1'                    as is_custom_tag,
        abstract = '1'                  as is_abstract,
        nullif(datatype, '')            as data_type,

        -- I for a value at a point in time, D for a value over a period.
        nullif(iord, '')                as period_type,

        -- D debit, C credit. Empty on 34,068 concepts, which is a genuine
        -- absence: the concept has no debit or credit nature. Nulled here so
        -- the accepted_values test on (D, C) measures wrong values rather than
        -- missing ones.
        nullif(crdr, '')                as balance_type,

        nullif(tlabel, '')              as tag_label,
        nullif(doc, '')                 as tag_documentation,

        _source_file,
        _ingested_at,
        _batch_id

    from deduplicated

)

select * from typed
