"""Run SQL against the warehouse and print the result. Read-only.

    .venv/Scripts/python src/query.py powerbi/verification-gates.sql
    .venv/Scripts/python src/query.py "SELECT * FROM marts.dim_company"

Given a .sql file, every section introduced by a `-- --- NAME` marker is run in
turn, with the comment lines under the marker printed above its result. That is
how the verification gates state their expected answer before showing the actual
one. Given anything else, the argument is run as a single query.

Safe to run while dbt or Power BI Desktop has the file open.
"""

import sys
from pathlib import Path

import duckdb

DB = Path(__file__).resolve().parents[1] / "data" / "db" / "sec_edgar.duckdb"
MARKER = "-- --- "


def show(con, title, notes, statement):
    if title:
        print("\n" + "=" * 78)
        print(title)
        print("=" * 78)
    for n in notes:
        print("  " + n)
    if notes:
        print()

    rel = con.sql(statement)
    rows, cols = rel.fetchall(), rel.columns
    fmt = lambda v: f"{v:,}" if isinstance(v, int) else str(v)

    widths = [
        max([len(c)] + [len(fmt(r[i])) for r in rows]) if rows else len(c)
        for i, c in enumerate(cols)
    ]
    line = lambda cells: "  " + "  ".join(c.ljust(w) for c, w in zip(cells, widths))
    print(line(cols))
    print(line(["-" * w for w in widths]))
    for r in rows:
        print(line([fmt(v) for v in r]))
    print(f"\n  ({len(rows)} row{'' if len(rows) == 1 else 's'})")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    arg = sys.argv[1]
    if not DB.exists():
        sys.exit(f"warehouse not found at {DB}\nrun the pipeline first")

    con = duckdb.connect(str(DB), read_only=True)
    path = Path(arg)

    if path.suffix.lower() == ".sql" and path.exists():
        blocks = path.read_text(encoding="utf-8").split(MARKER)[1:]
        if not blocks:
            sys.exit(f"no '{MARKER}' section markers in {path}")
        for block in blocks:
            header, _, body = block.partition("\n")
            notes = [l[3:].strip() for l in body.splitlines() if l.startswith("--")]
            sql = "\n".join(
                l for l in body.splitlines() if not l.lstrip().startswith("--")
            ).strip().rstrip(";").strip()
            if sql:
                show(con, header.replace("-", " ").strip(), [n for n in notes if n], sql)
    else:
        show(con, None, [], arg)

    print()


if __name__ == "__main__":
    main()
