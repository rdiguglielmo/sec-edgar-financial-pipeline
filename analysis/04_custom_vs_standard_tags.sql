-- Business question 4: what share of the concepts companies report are their
-- own inventions rather than standard US-GAAP, and what does that do to
-- comparability between companies?
--
-- ---------------------------------------------------------------------------
-- Why this query reads staging and not the marts
-- ---------------------------------------------------------------------------
-- This is a question about the source, not about the ten companies. The marts
-- are conformed to the analytical scope, where the answer is 114 custom names
-- against 379 standard ones; the source holds 106,845 against 5,700. A scope
-- level answer is a real answer but a narrow one, and the interesting figure is
-- how the two compare. So this reads the staging layer, which covers all 26,085
-- filings and all 14,619,494 facts, and reports the scope beside it.
--
-- That is a property of the question rather than a gap in the model, and it was
-- decided before the model was built; see section 8 of docs/modeling_decisions.md.
--
-- ---------------------------------------------------------------------------
-- Which flags this query uses, and why: none of the three
-- ---------------------------------------------------------------------------
-- is_consolidated, is_year_to_date and is_latest_report exist on the fact to
-- stop three different kinds of double counted money. This query counts neither
-- money nor economic events: it counts tagging decisions. Every row of num.txt
-- is one act of choosing a concept to report a figure under, and a segment
-- breakdown, a year to date total and a restated comparative are each a
-- separate such act. Filtering any of them out would answer a different
-- question, namely "what share of the distinct economic facts use a custom
-- tag", and would understate the tagging effort that is being measured.
--
-- The flags also do not exist at this layer, and that is deliberate rather than
-- an oversight: is_latest_report is derived per company across filings, which
-- is a marts concern. is_consolidated does exist in stg_num and is still not
-- used here, for the reason above.
--
-- The discriminator is version, not a name pattern. For a standard concept it
-- names the taxonomy, us-gaap/2025; for a company specific one it holds the
-- filing's own accession number. stg_tag exposes that as is_custom_tag, and the
-- two agree on all 329,861 concepts, so the flag is read rather than parsed.
--
-- Usage:
--   duckdb data/db/sec_edgar.duckdb < analysis/04_custom_vs_standard_tags.sql

-- ---------------------------------------------------------------------------
-- 1. The vocabulary against the volume
-- ---------------------------------------------------------------------------
-- Concepts are counted two ways on purpose. (tag_name, tag_version) is the key
-- the SEC declares, and it inflates custom concepts because every filing that
-- invents a tag gets its own version. Counting distinct names instead answers
-- "how many different ideas", and the gap between the two columns is itself the
-- finding.
select
    case when t.is_custom_tag then 'company specific' else 'standard taxonomy' end
                                                        as concept_kind,
    count(distinct t.concept_key)                       as concepts,
    count(distinct t.tag_name)                          as concept_names,
    round(100.0 * count(distinct t.concept_key)
          / sum(count(distinct t.concept_key)) over (), 2)
                                                        as pct_of_catalogue,
    sum(f.facts)                                        as facts,
    round(100.0 * sum(f.facts) / sum(sum(f.facts)) over (), 2)
                                                        as pct_of_facts
from staging.stg_tag t
left join (
    select concept_key, count(*) as facts
    from staging.stg_num
    group by concept_key
) f on f.concept_key = t.concept_key
group by 1
order by facts desc;

-- ---------------------------------------------------------------------------
-- 2. What that does to comparability
-- ---------------------------------------------------------------------------
-- A standard tag means the same thing in every filing, so it can be compared
-- across companies. A custom tag is defined by the company that wrote it, and
-- the question is whether any of them are shared in practice.
--
-- The reach is counted per use, not per name, and the difference is not
-- cosmetic. 151 tag names are custom for some companies and standard for
-- others, so a count grouped on the name alone credits a custom name with the
-- reach of its standard namesake. The discriminator is applied on the fact:
-- tag_version equals the filing's own accession number exactly when the company
-- invented the concept.
with fact_usage as (
    select
        n.tag_name,
        n.tag_version = n.accession_number      as is_custom_use,
        s.cik
    from staging.stg_num n
    join staging.stg_sub s using (accession_number)
),

name_reach as (
    select tag_name, is_custom_use, count(distinct cik) as companies
    from fact_usage
    group by 1, 2
)

select
    case when is_custom_use then 'company specific' else 'standard taxonomy' end
                                                        as concept_kind,
    count(*)                                            as concept_names,
    count(*) filter (where companies > 1)               as used_by_more_than_one_company,
    round(100.0 * count(*) filter (where companies > 1) / count(*), 2)
                                                        as pct_shared,
    max(companies)                                      as most_companies_on_one_name
from name_reach
group by 1
order by concept_names desc;

-- ---------------------------------------------------------------------------
-- 3. Why a shared name is not a shared concept
-- ---------------------------------------------------------------------------
-- The custom names with the widest reach are the clearest evidence that this is
-- vocabulary drift rather than a private dialect. Two of the top five are the
-- same words with one letter capitalised differently, filed by different
-- companies as different concepts. Nothing in the source relates them, and any
-- roll up that groups on the tag name treats them as two.
select
    n.tag_name,
    count(distinct s.cik)                               as companies,
    count(*)                                            as facts
from staging.stg_num n
join staging.stg_sub s using (accession_number)
where n.tag_version = n.accession_number                -- the company invented it
group by 1
order by companies desc
limit 10;

-- ---------------------------------------------------------------------------
-- 4. The same measure inside the analytical scope, company by company
-- ---------------------------------------------------------------------------
-- The comparison that matters for the rest of the project: ten large filers,
-- all in one industry, all filing complete annual cycles. If custom tagging
-- were an artifact of small or irregular filers, this is where it would drop to
-- nothing.
select
    c.company_name,
    count(*)                                                as facts,
    count(*) filter (where a.is_custom_tag)                 as custom_facts,
    round(100.0 * count(*) filter (where a.is_custom_tag) / count(*), 2)
                                                            as pct_custom_facts,
    count(distinct a.tag_name)                              as concept_names,
    count(distinct a.tag_name) filter (where a.is_custom_tag)
                                                            as custom_concept_names,
    round(100.0 * count(distinct a.tag_name) filter (where a.is_custom_tag)
          / count(distinct a.tag_name), 2)                  as pct_custom_names
from marts.fct_financial_facts f
join marts.dim_company c on c.company_key = f.company_key
join marts.dim_account a on a.account_key = f.account_key
group by 1
order by pct_custom_facts desc;
