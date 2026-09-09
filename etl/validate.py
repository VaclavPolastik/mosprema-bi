# -*- coding: utf-8 -*-
"""Kontroly nad vystupem ETL. Spousti se po build_warehouse.py:

    python etl/validate.py

Kontroluje tri veci, ktere se pri rucni praci nejcasteji rozejdou:

1. SQL v postgres/*.sql se parsuje skutecnou gramatikou PostgreSQL (pglast).
2. Poradi sloupcu v CSV odpovida poradi sloupcu v CREATE TABLE — jinak
   \\copy spadne az u zakaznika, ne tady.
3. Data drzi zakladni domenove predpoklady (rozsahy, klice, souvislost casu).

Kontrola 1 potrebuje balicek pglast (pip install pglast); bez nej se preskoci
a ohlasi to, aby se tichy vypadek nezamenil za uspech.
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
PG = ROOT / "postgres"

failures: list[str] = []
skipped: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"OK   {name}")
    else:
        failures.append(f"{name}: {detail}")
        print(f"FAIL {name}  {detail}")


# ---------------------------------------------------------------------
# 1. Gramatika SQL
# ---------------------------------------------------------------------
def check_sql_grammar() -> dict[str, list[str]]:
    try:
        import pglast
        from pglast import ast
    except ImportError:
        skipped.append("kontrola SQL preskocena (chybi pglast)")
        print("SKIP kontrola SQL — nainstaluj pglast: pip install pglast")
        return {}

    tables: dict[str, list[str]] = {}
    for f in sorted(PG.glob("*.sql")):
        # psql meta-prikazy (\copy, \set) nejsou soucasti SQL gramatiky
        sql = "\n".join(l for l in f.read_text(encoding="utf-8").splitlines()
                        if not l.lstrip().startswith("\\"))
        try:
            stmts = pglast.parse_sql(sql)
            check(f"SQL {f.name} ({len(stmts)} prikazu)", True)
            for stmt in stmts:
                node = stmt.stmt
                if isinstance(node, ast.CreateStmt):
                    tables[node.relation.relname] = [
                        e.colname for e in node.tableElts if isinstance(e, ast.ColumnDef)]
        except Exception as exc:
            check(f"SQL {f.name}", False, str(exc))
    return tables


# ---------------------------------------------------------------------
# 2. CSV vs DDL
# ---------------------------------------------------------------------
def check_columns(tables: dict[str, list[str]]) -> None:
    for name, cols in tables.items():
        path = OUT / f"{name}.csv"
        if not path.exists():
            check(f"sloupce {name}", False, "CSV neexistuje")
            continue
        with path.open(encoding="utf-8") as fh:
            header = next(csv.reader(fh))
        check(f"sloupce {name} ({len(cols)})", header == cols,
              f"CSV={header} DDL={cols}")


# ---------------------------------------------------------------------
# 3. Domenove predpoklady
# ---------------------------------------------------------------------
def check_data() -> None:
    daily = pd.read_csv(OUT / "fact_daily.csv", parse_dates=["date"])
    reading = pd.read_csv(OUT / "fact_reading.csv", parse_dates=["ts_local"])
    dev = pd.read_csv(OUT / "fact_development.csv", parse_dates=["date"])
    dim_date = pd.read_csv(OUT / "dim_date.csv", parse_dates=["date"])
    sensors = pd.read_csv(OUT / "dim_sensor.csv")

    check("dim_date je souvisla rada",
          (dim_date["date"].diff().dropna() == pd.Timedelta("1D")).all(),
          "v kalendari chybi den")

    check("fact_daily ma unikatni date_key", daily["date_key"].is_unique)
    check("kazdy den faktu je v kalendari",
          set(daily["date_key"]).issubset(set(dim_date["date_key"])))
    check("kazde cidlo v datech je v katalogu",
          set(reading["sensor_key"]).issubset(set(sensors["sensor_key"])))

    check("teplota vody je ve fyzikalnim rozsahu",
          daily["water_temp_c"].dropna().between(-30, 45).all(),
          f"min={daily['water_temp_c'].min()}, max={daily['water_temp_c'].max()}")
    check("vyska hladiny neni zaporna",
          (daily["water_level_cm"].dropna() >= 0).all(),
          f"min={daily['water_level_cm'].min()}")
    check("pokryti dne je 0-100 %",
          daily["coverage_pct"].between(0, 100).all())

    check("pct_complete je 0-100",
          dev["pct_complete"].between(0, 100).all())
    check("kumulace vyvoje neklesa",
          dev.groupby(["cohort_id", "model_key"])["cumulative"]
             .apply(lambda s: (s.diff().dropna() >= -1e-9).all()).all(),
          "nekde v rade klesla kumulativni hodnota")
    check("kohorta konci nejpozdeji dnem kukleni",
          dev.groupby(["cohort_id", "model_key"])["is_complete"]
             .apply(lambda s: s.sum() <= 1).all(),
          "kohorta pokracuje i po dosazeni 100 %")

    dup = reading.duplicated(subset=["ts_local", "sensor_key"]).sum()
    check("zadne duplicitni cteni", dup == 0, f"{dup} duplicit")

    lp = ROOT / "influx" / "mosprema.lp"
    check("line protocol existuje a neni prazdny", lp.exists() and lp.stat().st_size > 0)


def main() -> None:
    print("=== kontrola vystupu ETL ===")
    tables = check_sql_grammar()
    if tables:
        check_columns(tables)
    check_data()

    print()
    for s in skipped:
        print(f"POZN: {s}")
    if failures:
        print(f"\n{len(failures)} kontrol selhalo:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("Vsechny kontroly prosly.")


if __name__ == "__main__":
    main()
