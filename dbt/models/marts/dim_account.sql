/*
    One row per accounting concept the scope actually reports.

    Rows in:  329,861
    Rows out: 1,066
    Discarded: 328,795 concepts that no fact in the scope references. The
    dimension is conformed to the fact: every row here is used by at least one
    row of fct_financial_facts, and nothing in the star joins to nothing.

    Grain: (tag_name, tag_version), which is the key the SEC declares for
    tag.txt, carried over from stg_tag as concept_key.

    Why the version has to stay in the key, and what it does to counting
    -------------------------------------------------------------------
    version names the taxonomy for a standard concept (us-gaap/2024) and the
    filing's own accession number for a company specific one. Both cases make
    the same tag name appear under several versions, so concepts and concept
    names are different counts:

        standard   726 concept rows over 379 distinct tag names
        custom     340 concept rows over 114 distinct tag names

    A standard concept is repeated because the same element exists in the 2024
    and 2025 taxonomies. A custom one is repeated because every filing that
    invents it gets its own version, so one company's tag counts once per
    filing. Collapsing the dimension to the tag name alone would fix the
    inflation and introduce something worse: two different companies that both
    invent Accruedreceipts would merge into one concept. The version stays, and
    tag_name is exposed as a column so that a count can state which of the two
    it means.

    Custom tags are kept rather than filtered to the standard taxonomy. Their
    share is business question 4, so removing them removes the answer. Within
    the scope they are 340 of 1,066 concepts (31.9%) carrying 1,337 of 22,604
    facts (5.9%); across the whole data set 106,845 distinct custom names carry
    8.54%. Any count of concepts has to say which basis it uses.

    tag_label is null on two concepts of the full catalogue,
    ContributionFromShareholders and Accruedreceipts, which is the finding a
    staging test turned up. Neither is used by the scope, so the not_null test
    passes here and fails there. That contrast is the point: the same rule
    measured at two layers says how far the defect actually reaches.
*/

with scope_filings as (

    select accession_number from {{ ref('dim_filing') }}

),

scope_concepts as (

    select distinct concept_key
    from {{ ref('stg_num') }}
    where accession_number in (select accession_number from scope_filings)

)

select
    t.concept_key                   as account_key,
    t.tag_name,
    t.tag_version,
    t.is_custom_tag,

    t.tag_label,
    t.tag_documentation,

    t.data_type,

    -- I for a value at a point in time, D for a value over a period.
    t.period_type,

    -- D debit, C credit, null on 94 of these 1,066 concepts, which have
    -- neither nature. It is what says whether a negative value is an error or
    -- a contra account behaving normally.
    t.balance_type,

    t.is_abstract

from {{ ref('stg_tag') }} t
join scope_concepts c on c.concept_key = t.concept_key
