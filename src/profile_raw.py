"""Profile the DuckDB raw layer and print the evidence behind docs/data_quality.md.

Every claim in the data quality document is a number produced here. Running this
script reproduces all of them, so the document can be checked rather than
trusted. The queries only read; nothing is written back to the warehouse.

Profiling deliberately runs before any modelling. The SEC data sets carry
several traps that change the shape of the dimensional model rather than merely
needing a clean up afterwards, and each one produces a plausible looking number
instead of an error when it is missed: facts broken down by segment coexist with
the consolidated figure, year to date durations coexist with the quarters they
already contain, and the same concept is reported under several standard tags.

Usage:
    python src/profile_raw.py
"""

from __future__ import annotations

import duckdb

from config import DUCKDB_PATH, RAW_SCHEMA

# The three US-GAAP tags that carry top line revenue. There is no single one:
# which of them a company uses is a reporting choice, not a property of the
# business, and a comparison built on any one of them silently drops the
# companies that picked another.
REVENUE_TAGS = (
    "'Revenues'",
    "'RevenueFromContractWithCustomerExcludingAssessedTax'",
    "'RevenueFromContractWithCustomerIncludingAssessedTax'",
)
REVENUE_IN = ", ".join(REVENUE_TAGS)

# Equity is split the same way, by whether noncontrolling interests are folded in.
EQUITY_IN = (
    "'StockholdersEquity', "
    "'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest'"
)

# Section title, question answered, SQL. Ordered from the shape of the data
# towards the anomalies inside it.
CHECKS: tuple[tuple[str, str, str], ...] = (
    (
        "Volume",
        "Rows held per raw table",
        """
        select 'sub' as table_name, count(*) as rows from raw.sub
        union all select 'tag', count(*) from raw.tag
        union all select 'pre', count(*) from raw.pre
        union all select 'num', count(*) from raw.num
        """,
    ),
    (
        "Volume",
        "Filings and companies covered",
        """
        select count(*) as filings,
               count(distinct adsh) as distinct_adsh,
               count(distinct cik) as distinct_cik,
               count(distinct sic) as distinct_sic
        from raw.sub
        """,
    ),
    (
        "Volume",
        "Filings by form type, top 10",
        """
        select form, count(*) as filings, count(distinct cik) as companies,
               round(100.0 * count(*) / sum(count(*)) over (), 2) as pct
        from raw.sub group by 1 order by 2 desc limit 10
        """,
    ),
    (
        "Company identity",
        "Companies filing under more than one name",
        """
        with names as (select cik, count(distinct name) as names from raw.sub group by 1)
        select count(*) as ciks_total,
               count(*) filter (where names > 1) as ciks_with_several_names,
               round(100.0 * count(*) filter (where names > 1) / count(*), 2) as pct,
               max(names) as max_names_for_one_cik
        from names
        """,
    ),
    (
        "Company identity",
        "Companies filing under more than one SIC code",
        """
        with codes as (select cik, count(distinct sic) as sics from raw.sub group by 1)
        select count(*) filter (where sics > 1) as ciks_with_several_sic,
               count(*) as ciks_total,
               round(100.0 * count(*) filter (where sics > 1) / count(*), 2) as pct
        from codes
        """,
    ),
    (
        "Company identity",
        "Filings carrying a former name, and filings with no SIC code",
        """
        select count(*) filter (where former <> '') as with_former_name,
               count(*) filter (where sic = '') as without_sic,
               count(*) filter (where fye = '') as without_fiscal_year_end,
               count(*) as filings
        from raw.sub
        """,
    ),
    (
        "Company identity",
        "Stored width of cik and fye",
        """
        select min(length(cik)) as cik_min_len, max(length(cik)) as cik_max_len,
               count(*) filter (where cik like '0%') as cik_with_leading_zero,
               count(*) filter (where fye like '0%') as fye_with_leading_zero
        from raw.sub
        """,
    ),
    (
        "Filing metadata",
        "Amendments, restated submissions, multi registrant and summary filings",
        """
        select count(*) filter (where form like '%/A') as amended_forms,
               count(*) filter (where prevrpt = '1') as flagged_previous_report,
               count(*) filter (where cast(nciks as int) > 1) as several_registrants,
               count(*) filter (where detail = '0') as without_detail,
               count(*) as filings
        from raw.sub
        """,
    ),
    (
        "Filing metadata",
        "Fiscal period and fiscal year left empty",
        """
        select count(*) filter (where fp = '') as fiscal_period_empty,
               count(*) filter (where fy = '') as fiscal_year_empty,
               count(*) filter (where period = '') as period_empty,
               count(*) as filings
        from raw.sub
        """,
    ),
    (
        "Filing metadata",
        "Acceptance timestamp earlier than the filing date, and impossible periods",
        """
        select count(*) filter (
                 where substr(accepted, 1, 10)
                       < strptime(filed, '%Y%m%d')::date::varchar) as accepted_before_filed,
               count(*) filter (where period > filed) as period_after_filed,
               count(*) as filings
        from raw.sub where period <> '' and filed <> ''
        """,
    ),
    (
        "Accounting concepts",
        "Custom versus standard concepts in the tag catalogue",
        """
        select case when custom = '1' then 'custom' else 'standard' end as kind,
               count(distinct tag || '|' || version) as distinct_concepts,
               round(100.0 * count(distinct tag || '|' || version)
                     / (select count(distinct tag || '|' || version) from raw.tag), 2) as pct
        from raw.tag group by 1 order by 2 desc
        """,
    ),
    (
        "Accounting concepts",
        "Custom versus standard concepts as a share of reported facts",
        """
        select case when version = adsh then 'custom' else 'standard' end as kind,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 2) as pct,
               count(distinct tag) as distinct_tags
        from raw.num group by 1 order by 2 desc
        """,
    ),
    (
        "Accounting concepts",
        "Taxonomy namespaces in use, top 8",
        """
        select case when version = adsh then '(company specific)' else version end as namespace,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 2) as pct
        from raw.num group by 1 order by 2 desc limit 8
        """,
    ),
    (
        "Accounting concepts",
        "Companies reporting revenue, by the standard tag they chose",
        f"""
        select n.tag, count(distinct s.cik) as companies, count(*) as facts
        from raw.num n join raw.sub s using (adsh)
        where s.form in ('10-K', '10-Q') and n.version <> n.adsh
          and n.segments = '' and n.coreg = '' and n.uom = 'USD'
          and n.qtrs in ('1', '4')
          and n.tag in ({REVENUE_IN}, 'RevenuesNetOfInterestExpense')
        group by 1 order by 2 desc
        """,
    ),
    (
        "Accounting concepts",
        "Companies using more than one revenue tag at once",
        f"""
        with used as (
          select s.cik, count(distinct n.tag) as revenue_tags
          from raw.num n join raw.sub s using (adsh)
          where s.form in ('10-K', '10-Q') and n.version <> n.adsh
            and n.segments = '' and n.coreg = '' and n.uom = 'USD'
            and n.qtrs in ('1', '4') and n.tag in ({REVENUE_IN})
          group by 1
        )
        select revenue_tags, count(*) as companies from used group by 1 order by 1
        """,
    ),
    (
        "Accounting concepts",
        "Companies reporting a bottom line, by the standard tag they chose",
        """
        select n.tag, count(distinct s.cik) as companies, count(*) as facts
        from raw.num n join raw.sub s using (adsh)
        where s.form in ('10-K', '10-Q') and n.version <> n.adsh
          and n.segments = '' and n.coreg = '' and n.uom = 'USD'
          and n.qtrs in ('1', '4')
          and n.tag in ('NetIncomeLoss', 'ProfitLoss',
                        'NetIncomeLossAvailableToCommonStockholdersBasic',
                        'IncomeLossFromContinuingOperations')
        group by 1 order by 2 desc
        """,
    ),
    (
        "Accounting concepts",
        "Concept catalogue stability across the four quarters",
        """
        with labels as (
          select tag, version, count(distinct tlabel) as labels from raw.tag group by 1, 2
        )
        select count(*) as distinct_concepts,
               count(*) filter (where labels > 1) as concepts_relabelled_mid_year
        from labels
        """,
    ),
    (
        "Reported facts",
        "Units of measure, top 8 of the distinct total",
        """
        select uom, count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 4) as pct
        from raw.num group by 1 order by 2 desc limit 8
        """,
    ),
    (
        "Reported facts",
        "Distinct units of measure",
        "select count(distinct uom) as distinct_uom from raw.num",
    ),
    (
        "Reported facts",
        "Missing values against the footnote that was supposed to explain them",
        """
        select case when value = '' then 'value missing' else 'value present' end as value_state,
               case when footnote = '' then 'no footnote' else 'footnote' end as footnote_state,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 4) as pct
        from raw.num group by 1, 2 order by 3 desc
        """,
    ),
    (
        "Reported facts",
        "Values that are not parseable as a number, and negative values",
        """
        select count(*) filter (where value <> '' and try_cast(value as double) is null)
                 as non_numeric,
               count(*) filter (where try_cast(value as double) < 0) as negative,
               round(100.0 * count(*) filter (where try_cast(value as double) < 0)
                     / count(*) filter (where value <> ''), 2) as pct_of_populated
        from raw.num
        """,
    ),
    (
        "Reported facts",
        "Duration covered by each fact, by the number of quarters it spans",
        """
        select case when cast(qtrs as int) <= 4 then qtrs else '5 and above' end
                 as quarters_spanned,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 3) as pct
        from raw.num group by 1 order by min(cast(qtrs as int))
        """,
    ),
    (
        "Reported facts",
        "Distinct durations present",
        """
        select count(distinct qtrs) as distinct_qtrs,
               min(cast(qtrs as int)) as min_qtrs,
               max(cast(qtrs as int)) as max_qtrs
        from raw.num
        """,
    ),
    (
        "Reported facts",
        "Consolidated figures against segment breakdowns",
        """
        select case when segments = '' then 'consolidated' else 'segment breakdown' end as kind,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 2) as pct,
               count(*) filter (where segments is null) as null_segments
        from raw.num group by 1 order by 2 desc
        """,
    ),
    (
        "Reported facts",
        "Facts attributed to a co-registrant rather than the filer",
        """
        select case when coreg = '' then 'filer' else 'co-registrant' end as attributed_to,
               count(*) as facts,
               round(100.0 * count(*) / sum(count(*)) over (), 4) as pct
        from raw.num group by 1 order by 2 desc
        """,
    ),
    (
        "Keys and integrity",
        "Duplicates on the natural key the SEC declares for num.txt",
        """
        with keyed as (
          select adsh, tag, version, ddate, qtrs, uom, segments, coreg,
                 count(*) as rows, count(distinct value) as distinct_values
          from raw.num group by 1, 2, 3, 4, 5, 6, 7, 8
        )
        select count(*) as key_groups,
               count(*) filter (where rows > 1) as duplicated_keys,
               count(*) filter (where rows > 1 and distinct_values > 1) as with_conflicting_value,
               count(distinct adsh) filter (where rows > 1) as filings_affected
        from keyed
        """,
    ),
    (
        "Keys and integrity",
        "Duplicates on the declared keys of the other three files",
        """
        select 'pre (adsh, report, line)' as declared_key,
               count(*) filter (where rows > 1) as duplicated_keys
        from (select adsh, report, line, count(*) as rows from raw.pre group by 1, 2, 3)
        union all
        select 'tag (tag, version) within a quarter',
               count(*) filter (where rows > 1)
        from (select _source_file, tag, version, count(*) as rows
              from raw.tag group by 1, 2, 3)
        union all
        select 'sub (adsh)', count(*) filter (where rows > 1)
        from (select adsh, count(*) as rows from raw.sub group by 1)
        """,
    ),
    (
        "Keys and integrity",
        "Facts and presentation lines pointing at a filing or concept that is absent",
        """
        select 'num.adsh missing from sub' as broken_reference,
               (select count(*) from raw.num n
                where not exists (select 1 from raw.sub s where s.adsh = n.adsh)) as rows
        union all
        select 'pre.adsh missing from sub',
               (select count(*) from raw.pre p
                where not exists (select 1 from raw.sub s where s.adsh = p.adsh))
        union all
        select 'num.(tag, version) missing from tag',
               (select count(*) from raw.num n
                where not exists (select 1 from raw.tag t
                                  where t.tag = n.tag and t.version = n.version))
        union all
        select 'pre.(tag, version) missing from tag',
               (select count(*) from raw.pre p
                where not exists (select 1 from raw.tag t
                                  where t.tag = p.tag and t.version = p.version))
        """,
    ),
    (
        "Keys and integrity",
        "Statement each presentation line belongs to",
        """
        select case when stmt = '' then '(empty, undocumented)' else stmt end as stmt,
               count(*) as lines,
               round(100.0 * count(*) / sum(count(*)) over (), 2) as pct,
               count(distinct adsh) as filings
        from raw.pre group by 1 order by 2 desc
        """,
    ),
    (
        "Anomalies",
        "Period end dates outside a plausible range",
        """
        select count(*) as facts,
               round(100.0 * count(*) / (select count(*) from raw.num), 5) as pct,
               count(distinct ddate) as distinct_bad_dates,
               count(distinct adsh) as filings_affected,
               min(ddate) as earliest, max(ddate) as latest
        from raw.num
        where cast(substr(ddate, 1, 4) as int) not between 2010 and 2027
        """,
    ),
    (
        "Anomalies",
        "Restatements: standard facts a company reported in more than one filing",
        """
        with reported as (
          select s.cik, n.tag, n.version, n.ddate, n.qtrs, n.uom, n.segments, n.coreg,
                 n.value, n.adsh
          from raw.num n join raw.sub s using (adsh)
          where n.version <> n.adsh and s.form in ('10-K', '10-Q')
        ),
        grouped as (
          select cik, tag, version, ddate, qtrs, uom, segments, coreg,
                 count(distinct adsh) as filings, count(distinct value) as distinct_values
          from reported group by 1, 2, 3, 4, 5, 6, 7, 8
        )
        select count(*) as fact_keys,
               count(*) filter (where filings > 1) as reported_more_than_once,
               round(100.0 * count(*) filter (where filings > 1) / count(*), 2) as pct_repeated,
               count(*) filter (where filings > 1 and distinct_values > 1) as value_changed,
               round(100.0 * count(*) filter (where filings > 1 and distinct_values > 1)
                     / nullif(count(*) filter (where filings > 1), 0), 2) as pct_of_repeated
        from grouped
        """,
    ),
    (
        "Comparability",
        "Coverage of the accounts a financial comparison needs",
        f"""
        with cycle as (
          select cik from raw.sub where form in ('10-K', '10-Q') group by 1
          having count(distinct substr(_source_file, 1, 6)) = 4
             and count(*) filter (where form = '10-K') = 1
             and count(*) filter (where form = '10-Q') = 3
        ),
        facts as (
          select s.cik, n.tag, n.qtrs
          from raw.num n join raw.sub s using (adsh)
          where s.form in ('10-K', '10-Q') and n.version <> n.adsh
            and n.segments = '' and n.coreg = '' and n.uom = 'USD' and n.value <> ''
        ),
        coverage as (
          select c.cik,
            max(case when f.tag = 'Assets' and f.qtrs = '0' then 1 else 0 end) as assets,
            max(case when f.tag = 'LiabilitiesAndStockholdersEquity' and f.qtrs = '0'
                then 1 else 0 end) as balance_sheet_total,
            max(case when f.tag = 'Liabilities' and f.qtrs = '0' then 1 else 0 end) as liabilities,
            max(case when f.tag in ({EQUITY_IN}) and f.qtrs = '0' then 1 else 0 end) as equity,
            max(case when f.tag in ({REVENUE_IN}) and f.qtrs in ('1', '4')
                then 1 else 0 end) as revenue,
            max(case when f.tag in ('NetIncomeLoss', 'ProfitLoss') and f.qtrs in ('1', '4')
                then 1 else 0 end) as bottom_line,
            max(case when f.tag = 'OperatingIncomeLoss' and f.qtrs in ('1', '4')
                then 1 else 0 end) as operating_income,
            max(case when f.tag in ('CostOfRevenue', 'CostOfGoodsAndServicesSold')
                and f.qtrs in ('1', '4') then 1 else 0 end) as cost_of_revenue
          from cycle c left join facts f using (cik) group by 1
        )
        select count(*) as companies_with_a_full_filing_cycle,
               sum(assets) as assets, sum(balance_sheet_total) as balance_sheet_total,
               sum(equity) as equity, sum(liabilities) as liabilities,
               sum(revenue) as revenue, sum(bottom_line) as bottom_line,
               sum(operating_income) as operating_income,
               sum(cost_of_revenue) as cost_of_revenue
        from coverage
        """,
    ),
)


def render(connection: duckdb.DuckDBPyConnection, sql: str) -> str:
    """Run one query and return its result as a Markdown table."""
    relation = connection.sql(sql)
    headers = [description[0] for description in relation.description]
    rows = [
        ["" if value is None else str(value) for value in row]
        for row in relation.fetchall()
    ]

    widths = [
        max(len(headers[index]), *(len(row[index]) for row in rows)) if rows
        else len(headers[index])
        for index in range(len(headers))
    ]
    lines = [
        "| " + " | ".join(h.ljust(w) for h, w in zip(headers, widths)) + " |",
        "|" + "|".join("-" * (w + 2) for w in widths) + "|",
    ]
    lines += [
        "| " + " | ".join(v.ljust(w) for v, w in zip(row, widths)) + " |" for row in rows
    ]
    return "\n".join(lines)


def main() -> None:
    if not DUCKDB_PATH.exists():
        raise FileNotFoundError(
            f"No warehouse at {DUCKDB_PATH}. Run python src/load_raw.py first."
        )

    print(f"# Raw layer profile\n\nSource: {DUCKDB_PATH}, schema {RAW_SCHEMA}.")

    # Read only, so that profiling can never be the reason a number changed.
    with duckdb.connect(DUCKDB_PATH, read_only=True) as connection:
        section = None
        for check_section, title, sql in CHECKS:
            if check_section != section:
                section = check_section
                print(f"\n## {section}")
            print(f"\n### {title}\n")
            print(render(connection, sql))


if __name__ == "__main__":
    main()
