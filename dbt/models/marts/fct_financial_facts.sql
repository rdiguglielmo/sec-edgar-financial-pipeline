{{
    config(
        materialized = 'incremental',
        unique_key = 'fact_key',
        incremental_strategy = 'merge',
    )
}}

/*
    One row per numeric fact reported by a company in the scope.

    Rows in:  14,619,494
    Rows out: 22,604
    Discarded: 14,596,890 facts belonging to filings outside the scope. That is
    the only filter in this model. No duration filter, no consolidation filter,
    no unit filter, no dropping of rows with an empty value: the three modelling
    decisions of week 2 are already applied in stg_num and are not re-applied
    here.

    Grain: the eight fields the SEC declares unique for num.txt, hashed into
    fact_key. Inside the scope that key really is unique. It is not across the
    whole source, where 138 groups hold two rows, but all 138 belong to one
    filer outside the scope, so the unique test fails at staging and passes
    here. The same rule measured at two layers is how far the defect reaches.

    ------------------------------------------------------------------------
    The rule that picks one presentation line per fact
    ------------------------------------------------------------------------
    pre.txt has one row per presentation line and a concept appears on several
    lines of the same filing, so joining a fact to it fans out. Measured on the
    scope: 22,604 facts match 28,103 fact and line pairs, a 24.3% inflation, and
    every figure joined that way would be wrong by that much with nothing to
    show for it.

        facts on exactly one line          19,236   85.1%
        facts on more than one line         3,368   14.9%
        facts whose lines cross statements  2,938   13.0%
        facts with no presentation line         0

    The rule is: prefer a line that is not parenthetical, then the lowest report
    number, then the lowest line number. It returns exactly one line per fact,
    and the test assert_one_presentation_line_per_fact asserts that rather than
    trusting it.

    Parenthetical lines are preferred against, not excluded. A parenthetical
    line is a disclosure carried beside a statement line, common stock par value
    beside common stock, and it is the weaker answer to "which statement is this
    on". But 665 facts in the scope (2.9%) appear on parenthetical lines only,
    and excluding those lines would leave those facts with no statement at all.
    The difference between preferring and excluding is 665 facts of lost
    classification.

    The rule is a choice, and where it chooses it is recorded. Ordering by
    position rather than by a statement preference changes the answer on 18 of
    the 4,545 groups in the scope; a rule that ranked income statement first
    would change 54. Since no ordering is defensible on accounting grounds for a
    concept that genuinely appears on two statements, depreciation sits on both
    the income statement and the cash flow statement, the model takes the first
    line as filed and flags the rest: has_multiple_statement_lines on 3,368
    facts and spans_multiple_statements on 2,938, counted over every line of
    the concept including the parenthetical ones. The full mapping is not
    destroyed, it stays in stg_pre for anyone who needs every line.

    ------------------------------------------------------------------------
    The same economic fact reported by more than one filing
    ------------------------------------------------------------------------
    This is a double counting hazard the earlier profiling did not name, and it
    behaves exactly like qtrs and segments: it inflates a total quietly.

    A 10-Q carries the prior year comparative, so the same company, concept,
    period, duration, unit and breakdown is filed again by a later filing. In
    the scope, 22,604 fact rows carry only 20,764 distinct economic facts, and
    1,840 rows are superseded by a later filing.

    economic_fact_key identifies the fact across filings, is_latest_report marks
    the surviving version, and is_restated marks a row whose value differs from
    what an earlier filing reported for the same key. Restatements in the scope
    are two, both goodwill: Yum! Brands from 88 to 92 million at 2024-04-30 and
    Restaurant Brands from 479 to 481 million at 2024-05-31. Across all filings
    there are 19,451, which is why business question 5 is answered against the
    staging layer rather than here.

    No row is removed for any of this. Summing without a stance on duration, on
    consolidation, or on which filing reported it, remains possible and remains
    wrong; the flags are what make it a choice.

    ------------------------------------------------------------------------
    Why this model is incremental, and what the incremental has to look back at
    ------------------------------------------------------------------------
    Not for speed. 22,604 rows rebuild in about a second, and the measurement
    below says an incremental run still touches a third of them, so the saving
    is a fraction of a second. It is incremental because the write has to be an
    upsert: a row whose value the SEC corrects in a republished archive arrives
    with the same fact_key and has to replace the row that is there, not sit
    beside it. An append would keep both, and nothing downstream would notice.

    The strategy is merge, which is safe here and is not safe upstream. Inside
    the scope, fact_key is unique on all 22,604 rows, measured: zero duplicated
    keys. Across the whole source there are 138 duplicated keys, and MERGE drops
    one row of each pair without raising, which is why stg_num uses
    delete+insert instead. The same choice would be wrong in both places.

    The lookback is the part that would break if it were left out. Three columns
    here are computed across filings rather than within a row:
    economic_fact_key, is_latest_report and is_restated. Whether a row is still
    the current version of its economic fact depends on every other filing that
    reported the same fact, including rows already in this table. Processing
    only the newly landed rows would mark the new version current and leave the
    superseded one marked current too, and the total would double for exactly
    the rows the flag exists to protect.

    So the batch is not the new rows: it is every row sharing an
    economic_fact_key with a new row, and the merge rewrites the old members of
    each group with recomputed flags. Measured against the last archive loaded,
    2025q4: it brings 6,591 new rows and the lookback widens that to 7,797 rows,
    34.5% of the table. The widening is not an accident of this quarter. Every
    10-Q restates the prior year comparative, so a new archive necessarily
    reopens groups that already exist.

    Same limitation as stg_num: a row that a republished archive no longer
    contains stays here until dbt run --full-refresh rebuilds the model.
*/

with scope_filings as (

    select filing_key, accession_number, cik, filed_date
    from {{ ref('dim_filing') }}

),

scope_facts as (

    select
        n.*,
        f.filing_key,
        f.cik,
        f.filed_date,

        -- The fact across filings: the natural key with the filing replaced by
        -- the company that reported it. Computed once here because the
        -- incremental batch is defined in terms of it.
        md5(concat_ws('|', f.cik, n.tag_name, n.tag_version, n.period_end_date,
                      n.period_length_qtrs, n.unit_of_measure, n.segments,
                      n.coregistrant))                        as economic_fact_key

    from {{ ref('stg_num') }} n
    join scope_filings f on f.accession_number = n.accession_number

),

facts as (

    select * from scope_facts

    {% if is_incremental() %}
    -- Not the new rows: every row of every economic fact a new row belongs to.
    -- is_latest_report and is_restated are decided by comparing filings, so a
    -- group has to be recomputed whole or the superseded rows keep a stale flag.
    where economic_fact_key in (
        select economic_fact_key
        from scope_facts
        where _ingested_at > (select max(_ingested_at) from {{ this }})
    )
    {% endif %}

),

scope_lines as (

    select p.*
    from {{ ref('stg_pre') }} p
    where p.accession_number in (select accession_number from scope_filings)

),

line_counts as (

    select
        accession_number,
        concept_key,
        count(*)                        as presentation_line_count,
        count(distinct statement_code)  as statement_count
    from scope_lines
    group by accession_number, concept_key

),

chosen_line as (

    select
        accession_number,
        concept_key,
        statement_code,
        line_number,
        presentation_label
    from scope_lines
    qualify row_number() over (
        partition by accession_number, concept_key
        order by is_parenthetical, report_number, line_number
    ) = 1

),

with_identity as (

    select
        f.*,

        row_number() over (
            partition by f.economic_fact_key
            order by f.filed_date desc, f.accession_number desc
        )                                                       as report_recency,

        lag(f.value) over (
            partition by f.economic_fact_key
            order by f.filed_date, f.accession_number
        )                                                       as previously_reported_value

    from facts f

)

select
    f.fact_natural_key                              as fact_key,
    f.economic_fact_key,

    md5(f.cik)                                      as company_key,
    f.filing_key,
    f.concept_key                                   as account_key,
    md5(l.statement_code)                           as statement_key,
    f.period_end_date                               as period_end_key,

    f.period_length_qtrs,
    f.is_year_to_date,

    f.unit_of_measure,
    f.segments,
    f.is_consolidated,
    f.coregistrant,

    f.value,
    f.footnote,
    f.has_footnote,

    -- Zero rows in the scope carry this. It is kept so that the flag travels
    -- with the grain it describes rather than living only in staging, and so
    -- that a scope which later includes the affected filer inherits the
    -- warning instead of the surprise.
    f.has_duplicate_natural_key,

    n.presentation_line_count > 1                   as has_multiple_statement_lines,
    n.statement_count > 1                           as spans_multiple_statements,
    l.line_number                                   as presentation_line_number,
    l.presentation_label,

    f.report_recency = 1                            as is_latest_report,
    f.value is not null
        and f.previously_reported_value is not null
        and f.value <> f.previously_reported_value  as is_restated,

    -- Carried from the raw layer rather than left behind in staging, because
    -- the incremental batch above is defined on it. Without it the only
    -- available predicate would be "this key is not in the table yet", which
    -- cannot see a corrected value arriving for a key that is already here,
    -- and that is precisely the case the merge exists to handle.
    f._ingested_at,
    f._batch_id

-- Left joins, although every one of the 22,604 facts matches a presentation
-- line today and neither join drops a row. An inner join would turn a future
-- fact with no line into a row that quietly disappears, which is the one thing
-- this layer is not allowed to do. A miss surfaces instead as a null
-- statement_key, and the not_null test on that column reports it.
from with_identity f
left join chosen_line l
       on l.accession_number = f.accession_number
      and l.concept_key      = f.concept_key
left join line_counts n
       on n.accession_number = f.accession_number
      and n.concept_key      = f.concept_key
