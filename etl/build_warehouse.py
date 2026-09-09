# -*- coding: utf-8 -*-
"""ETL: surovy export ze stanice mosprema_206 -> hvezdicove schema pro BI.

Vstup
-----
data/raw/mosprema206.xlsx - dlouhy format tak, jak ho vraci ThingsBoard:
jeden radek na (cas, velicina). Sloupce jsou v exportu uvozeny apostrofy
('ts', 'key', ...), hodnoty obcas nesou jednotku jako text ("12 cm").

Vystup (out/)
-------------
dim_*.csv        - dimenze (datum, cidlo, stanice, druh, model, jakost)
fact_reading     - zrno: jedno cteni jednoho cidla (dlouhy format, 18 velicin)
fact_daily       - zrno: jeden den stanice (denni agregace podle pravidel BP)
fact_gap         - souvisle vypadky mereni (gaps-and-islands)
fact_development - zrno: den x druh x model (vyvoj larev, 0-100 %)
influx/mosprema.lp - Influx line protocol pro telemetrii
etl_report.json / etl_report.md - protokol behu a prehled jakosti dat

Domenova pravidla jsou prevzata z modelu bakalarske prace
(larval_app_advanced/prediction.py, data_io.py, species.py); kazda konstanta
ma u sebe odkaz na misto, odkud pochazi, aby dashboard nezacal zit vlastnim
zivotem oproti textu prace.
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw" / "mosprema206.xlsx"
OUT = ROOT / "out"
INFLUX = ROOT / "influx"

# --------------------------------------------------------------------------
# Konstanty modelu (BP, larval_app_advanced)
# --------------------------------------------------------------------------
LOCAL_TZ = "Europe/Prague"
STATION_ID = 206
STATION_NAME = "mosprema_206"
STATION_LAT = 49.703           # config.py: vychozi souradnice stanice
STATION_LON = 17.070

WATER_LOW_THRESHOLD_CM = 2.0       # prediction.py
WATER_LOW_DAYS_FOR_DEATH = 3       # prediction.py
WATER_AIR_EXCHANGE_K = 0.29        # prediction.py, fit temp_1 ~ temp_air
SHALLOWEST_SENSOR_DEPTH_CM = 25.0  # prediction.py
DIST_REL_OFFSET_CM = 3.30          # prediction.py, systematicky posun nahrady
DIST_REL_SPREAD_CM = 3.43          # prediction.py, sm. odchylka rozdilu

# Podil vyvoje, na kterem zacina instar 3 a instar 4 (species.py: 40 % / 67 %).
STAGE2_PCT = 0.40
STAGE3_PCT = 0.67

# Kohorta nesmi zacit driv nez 1. brezna. Bez teto zarazky by teple lednove dny
# roku 2024 (voda drzela nad 3,98 °C) nastartovaly kohortu Aedes cantans uprostred
# zimy, kdy druh jeste prezimuje ve vajickach.
COHORT_EARLIEST_MONTH = 3
COHORT_EARLIEST_DAY = 1

EXPECTED_READINGS_PER_DAY = 24     # stanice hlasi v hodinovem kroku

# --------------------------------------------------------------------------
# Katalog cidel - z nej vznika dim_sensor
# --------------------------------------------------------------------------
SENSORS = [
    # key, label, kategorie, jednotka, hloubka, min, max, jadro
    ("temp_1", "Teplota vody – dolní čidlo", "Teplota", "°C", 0.0, -40.0, 60.0, True),
    ("temp_2", "Teplota vody – střední čidlo", "Teplota", "°C", 40.0, -40.0, 60.0, True),
    ("temp_3", "Teplota vody – horní čidlo", "Teplota", "°C", 80.0, -40.0, 60.0, True),
    ("temp_air", "Teplota vzduchu", "Teplota", "°C", None, -40.0, 60.0, True),
    ("soil_temp", "Teplota půdy", "Teplota", "°C", None, -40.0, 60.0, False),
    ("dist_comp_rel", "Výška hladiny (kompenzovaná)", "Hladina", "cm", None, 0.0, 400.0, True),
    ("dist_rel", "Výška hladiny (nekompenzovaná)", "Hladina", "cm", None, 0.0, 400.0, True),
    ("dist_comp", "Vzdálenost k hladině (kompenzovaná)", "Hladina", "cm", None, 0.0, 1000.0, False),
    ("dist", "Vzdálenost k hladině (surová)", "Hladina", "cm", None, 0.0, 1000.0, False),
    ("hum_air", "Vlhkost vzduchu", "Atmosféra", "%", None, 0.0, 100.0, False),
    ("soil_hum", "Vlhkost půdy", "Atmosféra", "%", None, 0.0, 100.0, False),
    ("rain", "Srážky (kumulativní)", "Atmosféra", "mm", None, 0.0, 500.0, False),
    ("rain_delta", "Srážky (přírůstek)", "Atmosféra", "mm", None, 0.0, 200.0, False),
    ("bat", "Napětí baterie", "Technika", "mV", None, 3000.0, 4200.0, False),
    ("signal", "Síla signálu (RSSI)", "Technika", "dBm", None, -120.0, 0.0, False),
    ("X", "Náklon – osa X", "Technika", "°", None, 0.0, 180.0, False),
    ("Y", "Náklon – osa Y", "Technika", "°", None, 0.0, 180.0, False),
    ("Z", "Náklon – osa Z", "Technika", "°", None, 0.0, 180.0, False),
]

# --------------------------------------------------------------------------
# Druhy - Briere-2 z species.py, prahy degree-days z testu konstantnich teplot
# --------------------------------------------------------------------------
SPECIES = [
    # key, label, t0, tm, a, m, cutoff (= T_base), prah instaru 4 [degree-days], tm mereno, pozn.
    ("aedes_cantans", "Aedes cantans", 0.54, 30.00, 5.699281e-05, 2.0, 3.98, 242, True,
     "Horní práh 30 °C odpovídá údaji „no development“ v Becker et al. (obr. 2.10)."),
    ("aedes_vexans", "Aedes vexans", 5.71, 40.00, 6.500413e-05, 2.0, 8.49, 140, False,
     "Horní práh není daty určen, jde o předpoklad."),
    ("culex_pipiens", "Culex pipiens", 4.64, 40.00, 6.209714e-05, 2.0, 7.20, 152, False,
     "Horní práh není daty určen, jde o předpoklad."),
]

MODELS = [
    ("zakladni", "Základní (teplotní suma)",
     "Lineární suma stupňodnů nad T_base; práh instaru 4 z testu konstantních teplot.", "°D"),
    ("pokrocily", "Pokročilý (Brière-2)",
     "Nellineární rychlost vyvoje r(T) = a·T·(T−T0)·(Tm−T)^(1/m), výstup je podíl vývoje.", "podíl"),
]

QUALITY = [
    ("OK", "V pořádku", "Hodnota je v očekávaném rozsahu čidla.", 0),
    ("MIMO_ROZSAH", "Mimo fyzikální rozsah",
     "Hodnota leží mimo rozsah, který čidlo může smysluplně vrátit.", 2),
    ("ZAPORNA_HLADINA", "Záporná výška hladiny",
     "Doložená porucha hladinoměru: vrací shluk hodnot kolem −280 až −426 cm místo vzdálenosti.", 3),
    ("KONSTANTNI", "Trvale konstantní",
     "Čidlo vrací po celou dobu tutéž hodnotu – neměří.", 2),
    ("CHYBI", "Chybí hodnota", "Prázdná nebo nečíselná hodnota.", 1),
]

MONTHS_CS = ["leden", "únor", "březen", "duben", "květen", "červen",
             "červenec", "srpen", "září", "říjen", "listopad", "prosinec"]
MONTHS_CS_SHORT = ["led", "úno", "bře", "dub", "kvě", "čvn",
                   "čvc", "srp", "zář", "říj", "lis", "pro"]
DAYS_CS = ["pondělí", "úterý", "středa", "čtvrtek",
           "pátek", "sobota", "neděle"]
DAYS_CS_SHORT = ["po", "út", "st", "čt", "pá", "so", "ne"]
SEASON_CS = {12: "zima", 1: "zima", 2: "zima", 3: "jaro", 4: "jaro", 5: "jaro",
             6: "léto", 7: "léto", 8: "léto",
             9: "podzim", 10: "podzim", 11: "podzim"}

report: dict = {"kroky": [], "jakost": {}, "vystupy": {}}


def log(msg: str) -> None:
    print(msg)
    report["kroky"].append(msg)


# --------------------------------------------------------------------------
# 1. Nacteni a vycisteni
# --------------------------------------------------------------------------
def load_readings() -> pd.DataFrame:
    df = pd.read_excel(RAW)
    df.columns = [str(c).strip().replace("'", "") for c in df.columns]
    log(f"Nacteno {len(df):,} radku z {RAW.name} (sloupce: {', '.join(df.columns)}).")

    df["sensor_key"] = df["key"].astype(str).str.strip().str.replace("'", "", regex=False)
    # Hodnota obcas nese jednotku jako text ("12 cm") - stejne osetreni jako v data_io.py.
    df["value"] = pd.to_numeric(
        df["value"].apply(lambda x: str(x).replace("cm", "").strip()), errors="coerce"
    )
    df["ts_utc"] = pd.to_datetime(df["ts"], unit="ms", utc=True)
    df["ts_local"] = df["ts_utc"].dt.tz_convert(LOCAL_TZ).dt.tz_localize(None)
    df["date"] = df["ts_local"].dt.date

    dup = int(df.duplicated(subset=["ts_local", "sensor_key"], keep=False).sum())
    if dup:
        log(f"Nalezeno {dup} duplicitnich dvojic (cas, velicina) - slucuji prumerem.")
        df = (df.groupby(["ts_utc", "ts_local", "date", "sensor_key"], as_index=False)
                .agg(value=("value", "mean")))
    report["jakost"]["duplicitni_zaznamy"] = dup
    return df[["ts_utc", "ts_local", "date", "sensor_key", "value"]].copy()


def flag_quality(df: pd.DataFrame, sensors: pd.DataFrame) -> pd.DataFrame:
    """Priradi kazdemu cteni priznak jakosti podle katalogu cidel."""
    df = df.merge(sensors[["sensor_key", "min_valid", "max_valid"]], on="sensor_key", how="left")

    # Cidla, ktera po celou dobu vraceji jedinou hodnotu, nemeri.
    spread = df.groupby("sensor_key")["value"].nunique(dropna=True)
    dead = set(spread[spread <= 1].index)
    if dead:
        log(f"Trvale konstantni cidla (nemeri): {', '.join(sorted(dead))}.")
    report["jakost"]["konstantni_cidla"] = sorted(dead)

    is_level = df["sensor_key"].isin(["dist_rel", "dist_comp_rel"])
    df["quality_key"] = np.select(
        [
            df["value"].isna(),
            df["sensor_key"].isin(dead),
            is_level & (df["value"] < 0),
            (df["value"] < df["min_valid"]) | (df["value"] > df["max_valid"]),
        ],
        ["CHYBI", "KONSTANTNI", "ZAPORNA_HLADINA", "MIMO_ROZSAH"],
        default="OK",
    )
    counts = df["quality_key"].value_counts().to_dict()
    report["jakost"]["cetnost_priznaku"] = {k: int(v) for k, v in counts.items()}
    log("Jakost cteni: " + ", ".join(f"{k}={v:,}" for k, v in counts.items()))
    return df.drop(columns=["min_valid", "max_valid"])


# --------------------------------------------------------------------------
# 2. Denni agregace podle pravidel BP
# --------------------------------------------------------------------------
def to_wide(readings: pd.DataFrame) -> pd.DataFrame:
    """Dlouhy format -> siroky; vadne hodnoty se do modelu nepousteji."""
    clean = readings[readings["quality_key"] == "OK"]
    wide = clean.pivot_table(index="ts_local", columns="sensor_key", values="value", aggfunc="mean")
    return wide.reset_index()


def resolve_water_level(wide: pd.DataFrame) -> tuple[pd.Series, pd.Series]:
    """dist_comp_rel, jinak dist_rel posunuty o systematicky offset (prediction.py)."""
    def col(name):
        return wide[name] if name in wide.columns else pd.Series(np.nan, index=wide.index)

    primary, secondary = col("dist_comp_rel"), col("dist_rel")
    substituted = primary.isna() & secondary.notna()
    level = primary.where(~substituted, secondary + DIST_REL_OFFSET_CM)
    return level, substituted


def aggregate_daily(wide: pd.DataFrame, readings: pd.DataFrame) -> pd.DataFrame:
    """Jeden radek na den: teplota vody z cidla ve spravnem hloubkovem pasmu."""
    w = wide.copy()
    w["date"] = w["ts_local"].dt.date

    def col(name):
        return w[name] if name in w.columns else pd.Series(np.nan, index=w.index)

    height, substituted = resolve_water_level(w)
    t1, t2, t3 = col("temp_1"), col("temp_2"), col("temp_3")

    # Cidlo podle vysky hladiny: >=80 cm -> temp_3, >=40 cm -> temp_2, jinak temp_1.
    w["water_temp_c"] = np.select([height.isna(), height >= 80, height >= 40],
                                  [t1, t3, t2], default=t1)
    w["submerged_sensor"] = np.select([height.isna(), height >= 80, height >= 40],
                                      ["temp_1 (hladina neznámá)", "temp_3", "temp_2"],
                                      default="temp_1")
    w["water_level_cm"] = height
    w["level_substituted"] = substituted
    w["air_temp_c"] = col("temp_air")
    for extra in ("hum_air", "soil_temp", "soil_hum", "bat", "signal"):
        w[extra] = col(extra)

    daily = (w.groupby("date").agg(
        water_temp_c=("water_temp_c", "mean"),
        water_temp_min_c=("water_temp_c", "min"),
        water_temp_max_c=("water_temp_c", "max"),
        air_temp_c=("air_temp_c", "mean"),
        air_temp_min_c=("air_temp_c", "min"),
        air_temp_max_c=("air_temp_c", "max"),
        water_level_cm=("water_level_cm", "mean"),
        water_level_min_cm=("water_level_cm", "min"),
        # Kolik jednotlivych cteni za den kleslo pod prah vyschnuti. Pravidlo
        # uhynu z BP se vyhodnocuje z denniho PRUMERU, takze se nikdy nespusti;
        # tenhle sloupec ukazuje, ze na urovni jednotlivych cteni uz tri dny
        # po sobe pod prahem byly. Rozdil mezi obema pohledy je vysledek, ne chyba.
        low_level_readings=("water_level_cm",
                            lambda s: int((s < WATER_LOW_THRESHOLD_CM).sum())),
        level_substituted=("level_substituted", "any"),
        submerged_sensor=("submerged_sensor",
                          lambda s: s.mode().iat[0] if not s.mode().empty else None),
        air_hum_pct=("hum_air", "mean"),
        soil_temp_c=("soil_temp", "mean"),
        soil_hum_pct=("soil_hum", "mean"),
        battery_mv=("bat", "mean"),
        signal_dbm=("signal", "mean"),
    ).reset_index().sort_values("date").reset_index(drop=True))

    # Pokryti dne: kolik hodinovych slotu stanice skutecne nahlasila.
    slots = readings.groupby("date")["ts_local"].nunique().rename("n_readings").reset_index()
    daily = daily.merge(slots, on="date", how="left")
    daily["expected_readings"] = EXPECTED_READINGS_PER_DAY
    daily["coverage_pct"] = (daily["n_readings"] / EXPECTED_READINGS_PER_DAY * 100).clip(upper=100).round(1)

    return estimate_exposed_water_temperature(daily)


def estimate_exposed_water_temperature(daily: pd.DataFrame) -> pd.DataFrame:
    """Dny, kdy bylo i nejmelci cidlo nad hladinou: T_w(t) = T_w(t-1) + k*(T_a(t) - T_w(t-1))."""
    daily = daily.copy()
    height = daily["water_level_cm"]
    exposed = height.notna() & (height < SHALLOWEST_SENSOR_DEPTH_CM)

    water = daily["water_temp_c"].tolist()
    air = daily["air_temp_c"].tolist()
    estimated = [False] * len(daily)
    last_water = None

    for i in range(len(daily)):
        if not exposed.iloc[i]:
            if pd.notnull(water[i]):
                last_water = float(water[i])
            continue
        if pd.isnull(air[i]):
            est = last_water
        elif last_water is None:
            est = float(air[i])
        else:
            est = last_water + WATER_AIR_EXCHANGE_K * (float(air[i]) - last_water)
        if est is not None:
            water[i], estimated[i], last_water = est, True, est

    daily["water_temp_c"] = water
    daily["water_temp_estimated"] = estimated
    n = int(sum(estimated))
    log(f"Teplota vody dopoctena modelem vymeny tepla pro {n} dni (cidla nad hladinou).")
    report["jakost"]["dny_s_odhadnutou_teplotou"] = n
    return daily


# --------------------------------------------------------------------------
# 3. Vypadky mereni (gaps-and-islands nad hodinovou osou)
# --------------------------------------------------------------------------
def build_gaps(readings: pd.DataFrame) -> pd.DataFrame:
    stamps = pd.to_datetime(pd.Series(sorted(readings["ts_local"].unique())))
    grid = pd.date_range(stamps.min().floor("h"), stamps.max().ceil("h"), freq="h")
    present = set(stamps.dt.floor("h"))
    missing = pd.Series([g for g in grid if g not in present])

    rows = []
    if not missing.empty:
        # souvisle bloky = ostrovy v posloupnosti chybejicich hodin
        block = (missing.diff() != pd.Timedelta("1h")).cumsum()
        for _, part in missing.groupby(block):
            rows.append({
                "gap_start": part.iloc[0],
                "gap_end": part.iloc[-1] + pd.Timedelta("1h"),
                "missing_hours": len(part),
                "date": part.iloc[0].date(),
            })
    gaps = pd.DataFrame(rows)
    if not gaps.empty:
        gaps["gap_id"] = range(1, len(gaps) + 1)
        gaps["severity"] = pd.cut(gaps["missing_hours"], [0, 2, 12, 48, 10 ** 6],
                                  labels=["drobný", "krátký", "denní", "vícedenní"])
        gaps = gaps[["gap_id", "date", "gap_start", "gap_end", "missing_hours", "severity"]]
    tot = int(gaps["missing_hours"].sum()) if not gaps.empty else 0
    log(f"Vypadky mereni: {len(gaps)} bloku, celkem {tot} chybejicich hodin "
        f"({tot / len(grid) * 100:.1f} % casove osy).")
    report["jakost"]["vypadky_bloku"] = len(gaps)
    report["jakost"]["chybejici_hodiny"] = tot
    report["jakost"]["pokryti_casove_osy_pct"] = round(100 - tot / len(grid) * 100, 2)
    return gaps


# --------------------------------------------------------------------------
# 4. Model vyvoje larev
# --------------------------------------------------------------------------
def briere_rate(t, t0: float, tm: float, a: float, m: float, cutoff: float) -> float:
    if pd.isnull(t) or t < cutoff or t <= t0 or t >= tm:
        return 0.0
    return float(a * t * (t - t0) * (tm - t) ** (1.0 / m))


def death_mask(level: pd.Series) -> pd.Series:
    """True od dne, kdy hladina klesla pod 2 cm po 3 dny po sobe (pravidlo BP)."""
    low = (level < WATER_LOW_THRESHOLD_CM).fillna(False)
    run = low.groupby((~low).cumsum()).cumsum()
    return (run >= WATER_LOW_DAYS_FOR_DEATH).cummax()


def cohort_start(daily: pd.DataFrame, cutoff: float, year: int):
    """Kohorta startuje prvni den od 1. brezna, kdy teplota vody 3 dny po sobe drzi nad T_base.

    Pravidlo dashboardu, ne prace: BP nechava start na uzivateli. Je zvoleno tak,
    aby bylo reprodukovatelne a stejne pro vsechny druhy.
    """
    d = pd.to_datetime(daily["date"])
    earliest = pd.Timestamp(year=year, month=COHORT_EARLIEST_MONTH, day=COHORT_EARLIEST_DAY)
    part = daily[(d.dt.year == year) & (d >= earliest)].reset_index(drop=True)
    if part.empty:
        return None
    above = (part["water_temp_c"] >= cutoff).fillna(False)
    run = above.groupby((~above).cumsum()).cumsum()
    hit = part.index[run >= 3]
    if len(hit) == 0:
        return None
    first = hit[0]
    return part.loc[first - 2, "date"] if first >= 2 else part.loc[0, "date"]


def build_development(daily: pd.DataFrame) -> pd.DataFrame:
    rows = []
    years = sorted({pd.to_datetime(d).year for d in daily["date"]})

    for key, label, t0, tm, a, m, cutoff, dd_instar4, _tm_meas, _note in SPECIES:
        for year in years:
            start = cohort_start(daily, cutoff, year)
            if start is None:
                continue
            part = daily[(daily["date"] >= start)
                         & (pd.to_datetime(daily["date"]).dt.year == year)].reset_index(drop=True)
            if part.empty:
                continue

            dead = death_mask(part["water_level_cm"]).tolist()
            cohort_id = f"{key}_{year}"

            dd_total = dd_instar4 / STAGE3_PCT   # 100 % vyvoje dopocteno z prahu instaru 4

            def run(model_key, target, unit, step_fn):
                """Kumuluje vyvoj den po dni; konci dnem kukleni nebo uhynu kohorty."""
                cum = 0.0
                for i, r in part.iterrows():
                    step = 0.0 if dead[i] else step_fn(r["water_temp_c"])
                    cum = min(cum + step, target)
                    rows.append(_dev_row(r, cohort_id, key, model_key, step, cum,
                                         cum / target, dead[i], target, unit))
                    if dead[i] or cum >= target:
                        break   # kohorta skoncila, dalsi dny uz nic nepridaji

            # zakladni model: linearni suma stupnodnu nad T_base
            run("zakladni", dd_total, "°D",
                lambda t: 0.0 if pd.isnull(t) else max(0.0, float(t) - cutoff))
            # pokrocily model: nelinearni rychlost vyvoje Briere-2
            run("pokrocily", 1.0, "podíl",
                lambda t: briere_rate(t, t0, tm, a, m, cutoff))

    dev = pd.DataFrame(rows)
    log(f"Vyvojovy model spocten pro {dev['cohort_id'].nunique()} kohort "
        f"({dev['species_key'].nunique()} druhy x {len(MODELS)} modely), {len(dev):,} radku.")
    return dev


def _dev_row(r, cohort_id, species_key, model_key, step, cum, frac, is_dead, target, unit):
    pct = round(min(frac, 1.0) * 100, 3)
    if is_dead:
        stage = "larvy uhynuly"
    elif pct >= 100:
        stage = "kukleni"
    elif pct >= STAGE3_PCT * 100:
        stage = "instar 4"
    elif pct >= STAGE2_PCT * 100:
        stage = "instar 3"
    else:
        stage = "instar 1–2"
    return {
        "date": r["date"],
        "cohort_id": cohort_id,
        "species_key": species_key,
        "model_key": model_key,
        "water_temp_c": r["water_temp_c"],
        "daily_step": round(float(step), 6),
        "cumulative": round(float(cum), 6),
        "target": round(float(target), 2),
        "unit": unit,
        "pct_complete": pct,
        "stage": stage,
        "is_dead": bool(is_dead),
        "is_complete": bool(pct >= 100),
        "temp_estimated": bool(r["water_temp_estimated"]),
        "level_substituted": bool(r["level_substituted"]),
    }


# --------------------------------------------------------------------------
# 5. Dimenze
# --------------------------------------------------------------------------
def build_dim_date(d_from: date, d_to: date) -> pd.DataFrame:
    idx = pd.date_range(d_from, d_to, freq="D")
    df = pd.DataFrame({"date": idx})
    df["date_key"] = df["date"].dt.strftime("%Y%m%d").astype(int)
    df["year"] = df["date"].dt.year
    df["quarter"] = df["date"].dt.quarter
    df["month"] = df["date"].dt.month
    df["month_name"] = df["month"].map(lambda m: MONTHS_CS[m - 1])
    df["month_short"] = df["month"].map(lambda m: MONTHS_CS_SHORT[m - 1])
    df["year_month"] = df["date"].dt.strftime("%Y-%m")
    df["day"] = df["date"].dt.day
    df["day_of_year"] = df["date"].dt.dayofyear
    df["iso_week"] = df["date"].dt.isocalendar().week.astype(int)
    df["weekday"] = df["date"].dt.weekday + 1
    df["weekday_name"] = df["date"].dt.weekday.map(lambda w: DAYS_CS[w])
    df["weekday_short"] = df["date"].dt.weekday.map(lambda w: DAYS_CS_SHORT[w])
    df["is_weekend"] = df["weekday"] >= 6
    df["season"] = df["month"].map(SEASON_CS)
    # Vegetacni sezona = duben-zari, obdobi, kdy ma vyvoj larev smysl sledovat.
    df["is_growing_season"] = df["month"].between(4, 9)
    df["date"] = df["date"].dt.date
    # Poradi sloupcu musi sedet s DDL v postgres/01_schema.sql, jinak COPY spadne.
    return df[["date_key", "date", "year", "quarter", "month", "month_name", "month_short",
               "year_month", "day", "day_of_year", "iso_week", "weekday", "weekday_name",
               "weekday_short", "is_weekend", "season", "is_growing_season"]]


def build_dim_sensor() -> pd.DataFrame:
    return pd.DataFrame(SENSORS, columns=[
        "sensor_key", "sensor_label", "category", "unit", "depth_cm",
        "min_valid", "max_valid", "is_core"])


def build_dim_species() -> pd.DataFrame:
    df = pd.DataFrame(SPECIES, columns=[
        "species_key", "species_label", "briere_t0", "briere_tm", "briere_a", "briere_m",
        "t_base_c", "dd_instar4", "tm_is_measured", "note"])
    df["dd_total"] = (df["dd_instar4"] / STAGE3_PCT).round(1)
    df["dd_stage2"] = (df["dd_total"] * STAGE2_PCT).round(1)
    df["dd_stage3"] = df["dd_instar4"].astype(float)
    df["source"] = ("BECKER, N. a kol. Mosquitoes and Their Control, obr. 2.10; "
                    "parametry Brière-2 fitovány v BP (species.py).")
    return df


# --------------------------------------------------------------------------
# 6. Zapis vystupu
# --------------------------------------------------------------------------
def write_csv(df: pd.DataFrame, name: str) -> None:
    df.to_csv(OUT / f"{name}.csv", index=False, encoding="utf-8", lineterminator="\n")
    report["vystupy"][name] = {"radky": len(df), "sloupce": list(df.columns)}
    log(f"  {name}.csv  {len(df):>8,} radku  {len(df.columns):>2} sloupcu")


def write_line_protocol(readings: pd.DataFrame, sensors: pd.DataFrame, dev: pd.DataFrame) -> None:
    """Influx line protocol: telemetrie + modelovany vyvoj."""
    r = readings.merge(sensors[["sensor_key", "category"]], on="sensor_key", how="left")
    r = r[r["value"].notna()]
    ns = r["ts_utc"].astype("int64").astype(str)

    def esc(s):
        return str(s).replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")

    lines = ("sensor_reading,station=" + STATION_NAME
             + ",sensor=" + r["sensor_key"].map(esc)
             + ",category=" + r["category"].fillna("neznama").map(esc)
             + ",quality=" + r["quality_key"].map(esc)
             + " value=" + r["value"].round(4).astype(str)
             + " " + ns)

    d = dev.copy()
    d["ts_ns"] = (pd.to_datetime(d["date"]).dt.tz_localize(LOCAL_TZ)
                  .dt.tz_convert("UTC").astype("int64").astype(str))
    dev_lines = ("larval_development,station=" + STATION_NAME
                 + ",species=" + d["species_key"].map(esc)
                 + ",model=" + d["model_key"].map(esc)
                 + ",stage=" + d["stage"].map(esc)
                 + " pct_complete=" + d["pct_complete"].astype(str)
                 + ",cumulative=" + d["cumulative"].astype(str)
                 + ",daily_step=" + d["daily_step"].astype(str)
                 + " " + d["ts_ns"])

    path = INFLUX / "mosprema.lp"
    # newline musi byt vynuceno na LF. Bez toho Windows prepise kazde LF
    # na CRLF, InfluxDB pripocte CR k casovemu razitku a odmitne uplne
    # kazdy radek hlaskou "bad timestamp".
    payload = "\n".join(list(lines) + list(dev_lines)) + "\n"
    path.write_text(payload, encoding="utf-8", newline="\n")
    total = len(lines) + len(dev_lines)
    log(f"  influx/mosprema.lp  {total:,} radku line protocolu "
        f"({path.stat().st_size / 1e6:.1f} MB)")
    report["vystupy"]["mosprema.lp"] = {"radky": int(total)}


def main() -> None:
    OUT.mkdir(exist_ok=True)
    INFLUX.mkdir(exist_ok=True)

    sensors = build_dim_sensor()
    readings = load_readings()
    readings = flag_quality(readings, sensors)

    unknown = set(readings["sensor_key"]) - set(sensors["sensor_key"])
    if unknown:
        raise SystemExit(f"V datech jsou cidla mimo katalog: {sorted(unknown)}")

    wide = to_wide(readings)
    daily = aggregate_daily(wide, readings)
    gaps = build_gaps(readings)
    dev = build_development(daily)

    d_from, d_to = min(daily["date"]), max(daily["date"])
    dim_date = build_dim_date(d_from, d_to)
    log(f"Obdobi: {d_from} - {d_to} ({(d_to - d_from).days + 1} dni, {len(daily)} s merenim).")

    def dk(s):
        return pd.to_datetime(s).dt.strftime("%Y%m%d").astype(int)

    fact_reading = readings.assign(station_id=STATION_ID, date_key=dk(readings["date"]))
    fact_reading["value"] = fact_reading["value"].round(4)
    fact_reading = fact_reading[["date_key", "ts_local", "ts_utc", "station_id",
                                 "sensor_key", "quality_key", "value"]]

    fact_daily = daily.assign(station_id=STATION_ID, date_key=dk(daily["date"]))
    num = fact_daily.select_dtypes(include="number").columns
    fact_daily[num] = fact_daily[num].round(3)
    fact_daily = fact_daily[["date_key", "date", "station_id", "n_readings", "expected_readings",
                             "coverage_pct", "water_temp_c", "water_temp_min_c", "water_temp_max_c",
                             "water_temp_estimated", "submerged_sensor", "air_temp_c",
                             "air_temp_min_c", "air_temp_max_c", "water_level_cm",
                             "water_level_min_cm", "low_level_readings", "level_substituted",
                             "air_hum_pct", "soil_temp_c", "soil_hum_pct",
                             "battery_mv", "signal_dbm"]]

    fact_dev = dev.assign(station_id=STATION_ID, date_key=dk(dev["date"]))
    fact_dev = fact_dev[["date_key", "date", "station_id", "cohort_id", "species_key", "model_key",
                         "water_temp_c", "daily_step", "cumulative", "target", "unit",
                         "pct_complete", "stage", "is_dead", "is_complete",
                         "temp_estimated", "level_substituted"]]

    fact_gap = (gaps.assign(station_id=STATION_ID, date_key=dk(gaps["date"]))
                if not gaps.empty else gaps)

    log("Zapisuji vystupy:")
    write_csv(dim_date, "dim_date")
    write_csv(sensors, "dim_sensor")
    write_csv(pd.DataFrame([{
        "station_id": STATION_ID,
        "station_name": STATION_NAME,
        "latitude": STATION_LAT,
        "longitude": STATION_LON,
        "locality": "Tůň v lužním lese, okolí Olomouce",
        "first_reading": str(readings["ts_local"].min()),
        "last_reading": str(readings["ts_local"].max()),
    }]), "dim_station")
    write_csv(build_dim_species(), "dim_species")
    write_csv(pd.DataFrame(MODELS, columns=["model_key", "model_label", "model_note", "unit"]),
              "dim_model")
    write_csv(pd.DataFrame(QUALITY, columns=["quality_key", "quality_label",
                                             "quality_note", "severity"]), "dim_quality")
    write_csv(fact_reading, "fact_reading")
    write_csv(fact_daily, "fact_daily")
    write_csv(fact_dev, "fact_development")
    write_csv(fact_gap, "fact_gap")
    write_line_protocol(readings, sensors, dev)

    (OUT / "etl_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, default=str), encoding="utf-8")

    md = ["# Protokol behu ETL", "", "## Kroky", ""]
    md += [f"- {s}" for s in report["kroky"]]
    md += ["", "## Jakost dat", "", "| ukazatel | hodnota |", "|---|---|"]
    md += [f"| {k} | {v} |" for k, v in report["jakost"].items()]
    md += ["", "## Vystupy", "", "| tabulka | radku |", "|---|---|"]
    md += [f"| {k} | {v.get('radky')} |" for k, v in report["vystupy"].items()]
    (OUT / "etl_report.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\nHotovo.")


if __name__ == "__main__":
    main()
