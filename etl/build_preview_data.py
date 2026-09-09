# -*- coding: utf-8 -*-
import json, pandas as pd, numpy as np
from pathlib import Path

OUT = Path("out")
daily = pd.read_csv(OUT/"fact_daily.csv", parse_dates=["date"])
dev   = pd.read_csv(OUT/"fact_development.csv", parse_dates=["date"])
read  = pd.read_csv(OUT/"fact_reading.csv")
sens  = pd.read_csv(OUT/"dim_sensor.csv")
gaps  = pd.read_csv(OUT/"fact_gap.csv", parse_dates=["gap_start","gap_end"])
dimd  = pd.read_csv(OUT/"dim_date.csv", parse_dates=["date"])
spec  = pd.read_csv(OUT/"dim_species.csv")

def cz(d):
    return f"{d.day}. {d.month}."


def r(x, n=2):
    return None if pd.isna(x) else round(float(x), n)

# --- klouzavy prumer 7 dni (stejne jako v_daily_enriched) ---
daily = daily.sort_values("date").reset_index(drop=True)
daily["ma7"] = daily["water_temp_c"].rolling(7, min_periods=1).mean()

payload = {}

payload["meta"] = {
    "station": "mosprema_206",
    "od": str(daily["date"].min().date()),
    "do": str(daily["date"].max().date()),
    "dnuKalendar": int(len(dimd)),
}

payload["kpi"] = {
    "cteni": int(len(read)),
    "dnu": int(len(daily)),
    "okPct": round(100*(read["quality_key"]=="OK").mean(), 1),
    "odhadPct": round(100*daily["water_temp_estimated"].mean(), 1),
    "chybiHodin": int(gaps["missing_hours"].sum()),
    "vypadku": int(len(gaps)),
    "uptimePct": round(100*(1 - gaps["missing_hours"].sum()/(len(dimd)*24)), 1),
    "velicin": int(sens.shape[0]),
}

payload["daily"] = [
    [d.strftime("%Y-%m-%d"), r(w), r(a), r(l), r(m), int(e)]
    for d, w, a, l, m, e in zip(daily["date"], daily["water_temp_c"], daily["air_temp_c"],
                                daily["water_level_cm"], daily["ma7"], daily["water_temp_estimated"])
]

# --- vyvoj larev ---
lbl = dict(zip(spec["species_key"], spec["species_label"]))
d23 = dev[dev["date"].dt.year == 2023]
payload["dev"] = {}
for mk in ["zakladni", "pokrocily"]:
    payload["dev"][mk] = {}
    for sk, g in d23[d23["model_key"] == mk].groupby("species_key"):
        g = g.sort_values("date")
        payload["dev"][mk][sk] = {
            "label": lbl[sk],
            "body": [[dt.strftime("%Y-%m-%d"), r(p, 2)] for dt, p in zip(g["date"], g["pct_complete"])],
        }

# --- porovnani modelu ---
rows = []
for sk, g in d23.groupby("species_key"):
    e = {"druh": lbl[sk], "start": cz(g["date"].min())}
    for mk, key in [("zakladni", "z"), ("pokrocily", "p")]:
        gm = g[g["model_key"] == mk]
        fin = gm[gm["is_complete"]]
        e["kukleni_"+key] = cz(fin["date"].min()) if len(fin) else "—"
        e["dnu_"+key] = int(len(gm))
    e["rozdil"] = e["dnu_z"] - e["dnu_p"]
    rows.append(e)
payload["modelCmp"] = sorted(rows, key=lambda x: -x["rozdil"])

# --- jakost cidel ---
q = read.groupby("sensor_key").agg(
    cteni=("quality_key","size"),
    ok=("quality_key", lambda s: int((s=="OK").sum())),
    ruznych=("value","nunique"),
    minv=("value","min"), maxv=("value","max"),
).reset_index().merge(sens, on="sensor_key")
worst = (read[read["quality_key"]!="OK"].groupby("sensor_key")["quality_key"]
         .agg(lambda s: s.value_counts().index[0]).to_dict())
q["okPct"] = (100*q["ok"]/q["cteni"]).round(1)
q["vada"] = q["sensor_key"].map(worst).fillna("—")
payload["quality"] = [
    {"key": row.sensor_key, "label": row.sensor_label, "kat": row.category, "jed": row.unit,
     "cteni": int(row.cteni), "okPct": float(row.okPct), "ruznych": int(row.ruznych),
     "vada": row.vada, "min": r(row.minv), "max": r(row.maxv), "jadro": bool(row.is_core)}
    for row in q.sort_values(["okPct","sensor_key"]).itertuples()
]

# --- mesicni dostupnost ---
gaps["ym"] = gaps["gap_start"].dt.strftime("%Y-%m")
daily["ym"] = daily["date"].dt.strftime("%Y-%m")
dimd["ym"] = dimd["date"].dt.strftime("%Y-%m")
mg = gaps.groupby("ym")["missing_hours"].sum()
mk_ = dimd.groupby("ym").size()
md = daily.groupby("ym").size()
payload["monthly"] = [
    {"ym": ym, "dnu": int(mk_[ym]), "merenych": int(md.get(ym, 0)),
     "chybi": int(mg.get(ym, 0)),
     "uptime": round(100*(1 - mg.get(ym,0)/(mk_[ym]*24)), 1)}
    for ym in sorted(mk_.index)
]

# --- dny s ctenim pod prahem ---
payload["lowLevel"] = [
    {"date": f"{d.day}. {d.month}. {d.year}", "prumer": r(p), "min": r(mn), "cteni": int(c)}
    for d, p, mn, c in zip(daily.loc[daily["low_level_readings"]>0, "date"],
                           daily.loc[daily["low_level_readings"]>0, "water_level_cm"],
                           daily.loc[daily["low_level_readings"]>0, "water_level_min_cm"],
                           daily.loc[daily["low_level_readings"]>0, "low_level_readings"])
]

# --- nejdelsi vypadky ---
payload["gaps"] = [
    {"od": f"{s.day}. {s.month}. {s.year}, {s.hour:02d}:00", "hodin": int(h), "zav": z}
    for s, h, z in zip(*[gaps.sort_values("missing_hours", ascending=False).head(8)[c]
                         for c in ["gap_start","missing_hours","severity"]])
]

# --- cidlo pod vodou ---
payload["submerged"] = [{"k": k, "v": int(v)} for k, v in
                        daily["submerged_sensor"].value_counts().items()]

# --- parametry druhu ---
payload["species"] = [
    {"label": row.species_label, "tbase": float(row.t_base_c), "dd4": int(row.dd_instar4),
     "t0": float(row.briere_t0), "tm": float(row.briere_tm), "mereno": bool(row.tm_is_measured)}
    for row in spec.itertuples()
]

Path(r"C:\Users\PC\AppData\Local\Temp\claude\C--Users-PC-Desktop-pohovor\117021ec-9633-4a8b-8f84-a2c48ea1acb7\scratchpad\dashboard_data.json").write_text(
    json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print("bajtu:", Path(r"C:\Users\PC\AppData\Local\Temp\claude\C--Users-PC-Desktop-pohovor\117021ec-9633-4a8b-8f84-a2c48ea1acb7\scratchpad\dashboard_data.json").stat().st_size)
print("dni:", len(payload["daily"]), "| cidel:", len(payload["quality"]),
      "| mesicu:", len(payload["monthly"]), "| kohort:", len(payload["modelCmp"]))
print(json.dumps(payload["kpi"], ensure_ascii=False))
print(json.dumps(payload["modelCmp"], ensure_ascii=False, indent=1)[:600])
