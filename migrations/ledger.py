#!/usr/bin/env python3
"""The ledger as SQL, for a target where pgroll cannot run (README.md, "Where pgroll cannot run").

Each migration of <pgroll dir> (one JSON per migration in pgroll's grammar, as an app's ledger holds them:
pronto's `code.state.migrations`) is written to <out dir> as `<name>.sql`, its operations' `up` in order,
for ledger.sh to run. Every migration this plugin makes is one raw SQL operation; one with an operation of
another kind, or one pgroll would run out of order (`onComplete`), stops it before any database meets it.
A `.sql` of <out dir> no migration wrote this run (one a rebase renamed) is removed, since ledger.sh runs
every one it finds. Their names are the lint's to hold (migrate.ts check).

  usage: ledger.py <pgroll dir> <out dir>
"""
import json
import sys
from pathlib import Path


def ledger_sql(src: Path, out: Path) -> list[str]:
    """Each migration of `src` as `<name>.sql` in `out`, its operations' `up` in order; their names."""
    names = []
    for f in sorted(src.glob("*.json")):
        doc = json.loads(f.read_text())
        ops = doc.get("operations") if isinstance(doc, dict) else None
        if not isinstance(ops, list) or not ops:
            raise SystemExit(f"ledger.py: {f.name} is no pgroll migration: it holds no operations")
        ups = []
        for op in ops:
            sql = op.get("sql") if isinstance(op, dict) else None
            if not isinstance(sql, dict) or not isinstance(sql.get("up"), str):
                raise SystemExit(f"ledger.py: {f.name} has an operation that is not raw SQL, which ledger.sh cannot run")
            if sql.get("onComplete"):
                raise SystemExit(f"ledger.py: {f.name} has an onComplete operation, which pgroll runs after the others and ledger.sh would run in order")
            ups.append(sql["up"])
        (out / f"{f.stem}.sql").write_text("\n\n".join(ups) + "\n")
        names.append(f.stem)
    for stale in out.glob("*.sql"):
        if stale.stem not in names:
            stale.unlink()
    return names


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: ledger.py <pgroll dir> <out dir>")
    src, out = Path(argv[1]), Path(argv[2])
    if not src.is_dir():
        raise SystemExit(f"ledger.py: no directory {src}")
    out.mkdir(parents=True, exist_ok=True)
    for name in ledger_sql(src, out):
        print(name)


if __name__ == "__main__":
    main(sys.argv)
