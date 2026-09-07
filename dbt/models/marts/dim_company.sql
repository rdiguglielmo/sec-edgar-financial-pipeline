/*
    One row per company in the analytical scope.

    Rows in:  26,085 filings, covering 7,151 companies
    Rows out: 10
    Discarded: 7,141 companies, every one of them outside the scope defined by
    the scope_companies seed. This is the only place the scope filter is
    applied to a company, and every other mart inherits it by joining here.

    Grain and the slowly changing dimension decision
    ------------------------------------------------
    This is a type 1 dimension: one row per company, holding the last known
    value of every attribute. The alternative was a type 2, one row per version
    of the company with a validity range, and the numbers behind the choice are
    in docs/modeling_decisions.md. In short:

    - 172 of 7,151 companies (2.41%) file under more than one name across the
      four archives, at most three. 682 (9.54%) move some attribute.
    - A type 2 keyed on the name would hold 7,324 rows against 7,151, and
      versioning every attribute would hold 7,857.
    - Inside the scope it buys nothing measurable: none of the ten companies
      changed its name in 2025, so a type 2 dimension holds the same ten rows.
      Only Restaurant Brands moves at all, filing two different business state
      values, which a fully versioned dimension would turn into an eleventh row.

    The cost avoided is real. A type 2 forces the fact to resolve which version
    was current on the filing date, and a resolution written loosely multiplies
    the fact, which is the one thing this layer is not allowed to do.

    The rule is not silent. assert_one_company_name_per_cik still fails on all
    172 renaming companies at the staging layer, so the rate that justifies this
    choice stays measured on every run, and a jump in it means the rule needs
    revisiting.

    Which filing supplies the values
    --------------------------------
    The most recently filed one, ties broken by accession number. "Last known"
    has to name a rule, or it means whichever row the database happened to
    return.
*/

with scope as (

    select cik from {{ ref('scope_companies') }}

),

scope_filings as (

    select *
    from {{ ref('stg_sub') }}
    where cik in (select cik from scope)

),

name_history as (

    select
        cik,
        count(distinct company_name) as distinct_name_count
    from scope_filings
    group by cik

),

latest_filing as (

    select *
    from scope_filings
    qualify row_number() over (
        partition by cik
        order by filed_date desc, accession_number desc
    ) = 1

)

select
    md5(f.cik)                          as company_key,
    f.cik,

    f.company_name,
    f.former_company_name,
    f.name_changed_date,
    h.distinct_name_count > 1           as has_changed_name,

    f.sic_code,

    -- The quarterly archives ship no lookup table for SIC codes, so the two
    -- codes the scope covers are named here rather than joined. They name the
    -- same industry and the filer picks which one it reports; see docs/scope.md.
    case f.sic_code
        when '5812' then 'Eating places'
        when '5810' then 'Eating and drinking places'
    end                                 as industry_name,

    f.business_city,
    f.business_state,
    f.business_country,
    f.incorporation_state,
    f.incorporation_country,
    f.ein,

    f.fiscal_year_end_mmdd,
    f.filer_status

from latest_filing f
join name_history h using (cik)
