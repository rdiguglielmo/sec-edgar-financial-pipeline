-- Business question 5: how many reported facts were later restated, and which
-- companies concentrate those corrections?
--
-- ---------------------------------------------------------------------------
-- Why this query reads staging and not the marts
-- ---------------------------------------------------------------------------
-- Because inside the analytical scope the answer is two. Both are goodwill
-- adjustments of a few million dollars, and two data points are an anecdote
-- rather than an analysis. Across the whole source the same definition finds
-- nineteen thousand, so this reads the staging layer, which covers all 26,085
-- filings, and returns the scope's two at the end to show the difference.
--
-- That was decided before the marts were built rather than discovered
-- afterwards. See section 8 of docs/modeling_decisions.md.
--
-- ---------------------------------------------------------------------------
-- Which flags this query uses, and why
-- ---------------------------------------------------------------------------
--   is_latest_report              NOT AVAILABLE at this layer, on purpose. It
--                                 is derived by comparing filings of the same
--                                 company, which is a marts concern. This query
--                                 rebuilds that comparison itself, which is
--                                 what makes the definition visible instead of
--                                 inherited.
--
--   is_consolidated               NOT APPLIED. A restated segment breakdown is
--                                 a restatement. No double counting follows,
--                                 because segments is part of the key being
--                                 grouped on, so a consolidated figure and each
--                                 of its breakdowns are separate keys and
--                                 neither contains the other.
--
--   is_year_to_date               NOT APPLIED, for the same reason. A corrected
--                                 nine month figure is a correction. This query
--                                 counts keys whose value changed and never
--                                 sums a value, so the year to date hazard has
--                                 nothing to act on.
--
-- ---------------------------------------------------------------------------
-- What is filtered, and what it costs
-- ---------------------------------------------------------------------------
-- Two filters, both stated with the rows they discard, out of the 14,619,494
-- facts in stg_num:
--
--   form_type in ('10-K','10-Q')      discards 2,319,872 facts on registration
--                                     statements, amendments and other forms.
--                                     A periodic report is the thing that can
--                                     restate a prior periodic report.
--
--   standard concepts only            discards a further 919,289 facts. This is
--                                     not a preference, it is forced: for a
--                                     company specific concept tag_version
--                                     holds the filing's own accession number,
--                                     so the key can never repeat across
--                                     filings and a custom concept can never be
--                                     observed to be restated. Leaving them in
--                                     would pad the denominator with keys that
--                                     are unrepeatable by construction.
--
-- 11,380,333 facts remain.
--
-- ---------------------------------------------------------------------------
-- What counts as a restatement, and a correction to a published figure
-- ---------------------------------------------------------------------------
-- The flag the SEC ships for this is unusable. prevrpt is documented as marking
-- a submission that was later amended, and it is set on 5 filings out of
-- 26,085, only one of them a 10-Q. So the definition is measured instead: the
-- same company reporting the same concept, for the same period end, duration,
-- unit, segment breakdown and co-registrant, in more than one filing, with a
-- different number.
--
-- Repetition alone is not a restatement and is the normal case: every 10-Q
-- carries the prior year comparative, which is why one key in seven is reported
-- more than once. Only a changed number is a correction.
--
-- "A different number" is doing real work in that sentence. docs/data_quality.md
-- reports 20,929 restatements, counted over the raw layer where an unpopulated
-- value is an empty string and therefore counts as a value of its own. Under
-- that reading a figure reported once and then left blank registers as a
-- change. Separating the two:
--
--     19,369   the number changed between filings
--      1,541   the figure was reported once and left blank afterwards
--         19   keys held only by the qtrs > 4 long tail stg_num discards
--     ------
--     20,929   the published figure
--
-- A withdrawn figure is a real event and is worth counting, but it is not a
-- company saying a different number. Both are returned below rather than
-- folded together.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/05_restatement_analysis.sql

create or replace temp view reported_facts as
select
    s.cik,
    s.company_name,
    s.form_type,
    s.accession_number,
    s.filed_date,
    n.tag_name,
    n.period_end_date,
    n.period_length_qtrs,
    n.unit_of_measure,
    n.segments,
    n.value,
    -- The fact identified across filings: the natural key with the filing
    -- replaced by the company that reported it.
    md5(concat_ws('|', s.cik, n.tag_name, n.tag_version, n.period_end_date,
                  n.period_length_qtrs, n.unit_of_measure, n.segments,
                  n.coregistrant))                          as economic_fact_key
from staging.stg_num n
join staging.stg_sub s using (accession_number)
where s.form_type in ('10-K', '10-Q')
  and n.tag_version <> n.accession_number;                  -- standard concepts only

create or replace temp view fact_history as
select
    economic_fact_key,
    any_value(cik)                                          as cik,
    any_value(company_name)                                 as company_name,
    any_value(tag_name)                                     as tag_name,
    count(distinct accession_number)                        as filings,
    -- count(distinct) ignores nulls, so this counts distinct numbers rather
    -- than treating "not populated" as a number of its own.
    count(distinct value)                                   as distinct_values,
    count(value)                                            as populated_reports,
    count(*) - count(value)                                 as blank_reports,
    min(filed_date)                                         as first_filed,
    max(filed_date)                                         as last_filed
from reported_facts
group by economic_fact_key;

-- ---------------------------------------------------------------------------
-- 1. The headline, with the two kinds of change kept apart
-- ---------------------------------------------------------------------------
select
    count(*)                                                as economic_facts,
    count(*) filter (where filings > 1)                     as reported_more_than_once,
    round(100.0 * count(*) filter (where filings > 1) / count(*), 2)
                                                            as pct_repeated,
    count(*) filter (where filings > 1 and distinct_values > 1)
                                                            as value_changed,
    count(*) filter (where filings > 1 and distinct_values = 1
                       and blank_reports > 0 and populated_reports > 0)
                                                            as figure_withdrawn,
    round(100.0 * count(*) filter (where filings > 1 and distinct_values > 1)
          / nullif(count(*) filter (where filings > 1), 0), 2)
                                                            as pct_of_repeated_changed
from fact_history;

-- ---------------------------------------------------------------------------
-- 2. Which companies concentrate the corrections
-- ---------------------------------------------------------------------------
-- Restatements are not spread evenly, and the count on its own does not say
-- much: a company that files a lot repeats a lot. The share column is what
-- separates a company that corrected a handful of figures from one whose
-- filings disagree with each other across the board.
select
    company_name,
    cik,
    count(*) filter (where filings > 1)                     as facts_reported_twice,
    count(*) filter (where filings > 1 and distinct_values > 1)
                                                            as facts_restated,
    round(100.0 * count(*) filter (where filings > 1 and distinct_values > 1)
          / nullif(count(*) filter (where filings > 1), 0), 1)
                                                            as pct_of_repeats_restated,
    count(distinct tag_name) filter (where filings > 1 and distinct_values > 1)
                                                            as concepts_affected,
    min(first_filed)                                        as earliest_filing,
    max(last_filed)                                         as latest_filing
from fact_history
group by company_name, cik
having count(*) filter (where filings > 1 and distinct_values > 1) > 0
order by facts_restated desc
limit 20;

-- ---------------------------------------------------------------------------
-- 3. The same measure inside the analytical scope
-- ---------------------------------------------------------------------------
-- Two facts, which is the reason this question is answered against staging at
-- all. The full history of each is returned rather than a count, because with
-- two of them the history is the answer.
select
    h.company_name,
    h.tag_name,
    f.period_end_date,
    f.form_type,
    f.accession_number,
    f.filed_date,
    round(f.value / 1e6, 3)                                 as value_musd
from fact_history h
join reported_facts f using (economic_fact_key)
where h.filings > 1
  and h.distinct_values > 1
  and h.cik in (select cik from marts.dim_company)
order by h.company_name, f.filed_date;
