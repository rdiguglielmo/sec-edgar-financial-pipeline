/*
    A concept the taxonomy defines as a flow cannot be reported as a balance at
    a point in time, and the reverse.

    Expected to fail on 33 facts of the 22,604 in the scope, 0.15%. Across the
    whole data set the same contradiction appears on 93,087 facts of 14.6
    million, 0.64%.

    tag.txt declares each concept as I, a value at an instant, or D, a value
    over a duration. num.txt states how many quarters each fact spans, and 0
    means an instant. So qtrs = 0 on a concept declared D says the filer
    reported a flow as though it were a balance, which the two files cannot both
    be right about.

    The reverse direction, a duration on a concept declared I, is also tested
    and does not occur: 0 facts in the scope and 0 in the whole data set.

    This test is worth having because of what it is not. It does not measure the
    source being messy in general, which is already documented; it measures a
    contradiction between two of the source's own files, on a small and
    inspectable set of rows. It stays at error severity, and the 33 rows it
    returns name the concept and the value so the case can be read rather than
    counted.

    A test deliberately not written, for the record, so that nobody adds it
    later thinking it was forgotten: value sign against balance type. Credit
    nature concepts carry a negative value on 1,903 facts of the scope, 8.4%,
    and almost all of them are correct, because a contra account or a loss is
    negative by nature. A check that returns 1,903 rows of which a handful might
    matter buries the ones that do, and drains the credibility of every other
    check beside it. The same reasoning kept the accepted_at against filed_date
    check out of the staging layer.
*/

{{ config(meta = {'expected_failures': 33}) }}

select
    f.fact_key,
    a.tag_name,
    a.period_type           as concept_period_type,
    f.period_length_qtrs,
    f.period_end_date_label,
    f.value
from (
    select
        fact_key,
        account_key,
        period_length_qtrs,
        period_end_key      as period_end_date_label,
        value
    from {{ ref('fct_financial_facts') }}
) f
join {{ ref('dim_account') }} a on a.account_key = f.account_key
where (f.period_length_qtrs = 0 and a.period_type = 'D')
   or (f.period_length_qtrs > 0 and a.period_type = 'I')
