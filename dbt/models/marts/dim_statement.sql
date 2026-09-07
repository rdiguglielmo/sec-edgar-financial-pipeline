/*
    One row per financial statement code.

    Rows in:  2,965,835 presentation lines
    Rows out: 8
    Discarded: nothing. The model reads the distinct codes present in the
    source, so the dimension is a code list rather than a hand written lookup.

    This is the one dimension not conformed to the fact, and the exception is
    deliberate. Facts in the scope reference five of the eight codes: IS, BS,
    CF, EQ and CI. UN, SI and the undocumented empty string are kept because
    this is reference data, a complete list of what the source can say, and
    because dropping the empty code would delete a finding: the SEC documents
    seven codes and an eighth value occurs, on 257 lines across 8 filings, seven
    of them registration statements. The accepted_values test in schema.yml
    fails on that eighth value on purpose.

    Why the grain is the code and not the presentation line
    ------------------------------------------------------
    pre.txt has one row per presentation line, and a concept appears on several
    lines of the same filing. Turning that into the dimension would give 4,968
    rows for 22,604 facts inside the scope, one dimension row for every four and
    a half facts, and every row specific to a single filing so nothing conforms
    across companies. What an analysis slices by is the statement, and there are
    eight of those.

    The line the fact came from is not lost: fct_financial_facts carries
    presentation_line_number and presentation_label as degenerate attributes,
    with the rule that picked them written in that model.
*/

with codes as (

    select distinct statement_code
    from {{ ref('stg_pre') }}

)

select
    md5(statement_code)         as statement_key,
    statement_code,

    case statement_code
        when 'BS' then 'Balance sheet'
        when 'IS' then 'Income statement'
        when 'CF' then 'Cash flow'
        when 'EQ' then 'Statement of stockholders equity'
        when 'CI' then 'Comprehensive income'
        when 'SI' then 'Schedule of investments'
        when 'UN' then 'Unclassifiable statement'
        when ''   then 'Undocumented'
    end                         as statement_name,

    -- Reporting order rather than source order: the statements an analyst reads
    -- first come first, and the two the SEC documents but this project does not
    -- use trail behind them.
    case statement_code
        when 'IS' then 1
        when 'BS' then 2
        when 'CF' then 3
        when 'EQ' then 4
        when 'CI' then 5
        when 'SI' then 6
        when 'UN' then 7
        else 8
    end                         as display_order,

    statement_code <> ''        as is_documented

from codes
