# mosprema_206 — dashboard nad daty z bakalářské práce

Datová platforma nad měřeními ze senzorové stanice, která rok sledovala tůň
v lužním lese, a nad modelem vývoje komářích larev z bakalářské práce.
Stejná data ve čtyřech nástrojích, protože každý z nich odpovídá na jinou
otázku.

**Zdroj dat:** V. Polaštík, *Predikční model vývoje komářích larev*,
Katedra geoinformatiky, Univerzita Palackého v Olomouci.
Stanice `mosprema_206`, 15. 3. 2023 – 23. 3. 2024, hodinový krok.

**Náhled bez instalace:** <https://claude.ai/code/artifact/62ef87f2-ca28-4e1c-9f9b-4cf79e65b600>
— tatáž čísla a křivky jako v Grafaně, spočítané stejným ETL, jen jako statická
stránka. Zdroj je `docs/preview.html`.

---

## Co v datech je

| | |
|---|---|
| Čtení | **139 791** (18 veličin × 8 585 časových značek) |
| Dnů s měřením | **373** z 375 kalendářních |
| Platných čtení | **90,9 %** |
| Dostupnost časové osy | **95,4 %** (417 chybějících hodin ve 211 blocích) |
| Teplota vody dopočítaná, ne měřená | **63 % dnů** |

Veličiny: tři teploty vody v různých hloubkách (`temp_1` – `temp_3`), teplota
a vlhkost vzduchu, teplota a vlhkost půdy, čtyři varianty výšky hladiny,
srážky, napětí baterie, síla signálu a náklon stanice ve třech osách.

---

## Architektura

```
        mosprema206.xlsx  (dlouhý formát, 139 791 řádků)
                 │
                 ▼
        etl/build_warehouse.py ──► etl/validate.py  (27 kontrol)
                 │
     ┌───────────┴────────────┐
     ▼                        ▼
  out/*.csv               influx/mosprema.lp
  hvězdicové schéma       line protocol
     │                        │
     ├──► PostgreSQL          └──► InfluxDB
     │    (10 tabulek,             (telemetrie + modelovaný vývoj)
     │      9 pohledů)                  │
     │         │                        │
     │         └────────► Grafana ◄─────┘
     │                    (2 dashboardy)
     └──► Power BI
          (Power Query + DAX)
```

### Proč čtyři nástroje a ne jeden

To je otázka, kterou je dobré umět zodpovědět dřív, než ji někdo položí.

**PostgreSQL** je zdroj pravdy. Hvězdicové schéma, cizí klíče, devět
analytických pohledů. Sem patří všechno, co má vazby a musí platit — model
vývoje larev se odkazuje na druh, druh nese parametry z literatury, čtení
nese příznak jakosti. Relační databáze tyhle vazby uhlídá, časová řada ne.

**InfluxDB** drží tutéž telemetrii jako řadu. Zápis 140 tisíc bodů, dotaz
na posledních čtyřicet dní bez indexu, `aggregateWindow` místo ručního
`GROUP BY date_trunc`. Kdyby stanice běžela dál a posílala data živě,
šla by do Influxu a Postgres by dostával jen denní agregace.

**Grafana** je provozní pohled. Stav stanice, baterie, signál, výpadky —
věci, na které se člověk dívá průběžně a chce u nich alerty. Umí sáhnout
do obou databází zároveň, což je přesně její výhoda.

**Power BI** je analytický pohled. Nejde o graf, jde o model: hvězda,
kalendářní tabulka, míry v DAXu, průřezy, které fungují napříč stránkami.
Otázky typu „porovnej mi tenhle rok s loňským po měsících, jen pro dny se
skutečně měřenou teplotou" se v Grafaně dělají špatně a tady dobře.

---

## Rychlý start

### 1. ETL

```bash
cp .env.example .env
pip install -r etl/requirements.txt
python etl/build_warehouse.py
python etl/validate.py
```

Na Windows místo `cp` použij `copy .env.example .env`. Doplňovat v něm nic
nemusíš, hodnoty jsou vývojové a fungují tak, jak jsou.

Vznikne `out/*.csv` (hvězdicové schéma), `influx/mosprema.lp`
a `out/etl_report.md` (protokol běhu s přehledem jakosti).

### 2. PostgreSQL, InfluxDB a Grafana

Na Windows stačí jeden příkaz — ověří Docker, doplní chybějící výstupy ETL,
nastartuje kontejnery, počká na databázi a nahraje telemetrii do Influxu:

```powershell
.\start-stack.ps1
```

Ručně, nebo mimo Windows:

```bash
docker compose up -d && ./influx/load.sh
```

Postgres se při prvním startu sám naplní z `out/` a založí pohledy.

> **Po instalaci Docker Desktopu je nutný restart Windows.** Instalátor zapíná
> WSL 2 a Virtual Machine Platform a ty se aktivují až po rebootu; do té doby
> daemon hlásí `Docker Desktop is unable to start`. Po restartu spusť Docker
> Desktop, počkej, až ikona přestane blikat, a pak `start-stack.ps1`.

Pak:

| Služba | Adresa | Přihlášení |
|---|---|---|
| Grafana | http://localhost:3001 | `admin` / `admin` |
| InfluxDB | http://localhost:8086 | `mosprema` / `mosprema123` |
| PostgreSQL | `localhost:5432` | `mosprema` / `mosprema` |

Dashboardy se do Grafany načtou samy — složka **mosprema_206**.

Ověřeno 9. 9. 2026 na čisté instalaci: PostgreSQL 139 791 řádků a všech 9 pohledů
vrací data, InfluxDB 139 791 bodů telemetrie a 1 584 hodnot modelu, oba datové
zdroje v Grafaně hlásí OK a dotazy všech panelů vracejí data.

> Údaje jsou v `.env` a jsou vývojové. Všechny služby poslouchají jen na
> `127.0.0.1`. Na server s tímhle nechoď.

### 3. Power BI

Power BI Desktop pracuje s binárním `.pbix`, který nejde vygenerovat
skriptem. Report se staví ručně podle [`powerbi/BUILD.md`](powerbi/BUILD.md);
Power Query i DAX jsou hotové v [`powerbi/power_query.m`](powerbi/power_query.m)
a [`powerbi/measures.dax`](powerbi/measures.dax). Počítej se dvěma až třemi
hodinami.

---

## Co se v datech ukázalo

**Nelineární model dojde ke kuklení o dva týdny dřív než lineární.**
Pro kohortu roku 2023 vychází kuklení takhle:

| Druh | Start kohorty | Teplotní suma | Brière-2 | Rozdíl |
|---|---|---|---|---|
| *Aedes cantans* | 15. 3. | 25. 5. (72 dní) | 12. 5. (59 dní) | 13 dní |
| *Culex pipiens* | 21. 3. | 2. 6. (74 dní) | 23. 5. (64 dní) | 10 dní |
| *Aedes vexans* | 22. 3. | 9. 6. (80 dní) | 27. 5. (67 dní) | 13 dní |

Důvod je v tom, co každý model předpokládá. Lineární suma stupňodnů počítá,
že se rychlost vývoje zvedá s teplotou pořád stejně. Brièreova křivka
připouští, že mezi patnácti a pětadvaceti stupni roste rychleji než
lineárně — a přesně v tom pásmu se voda v tůni přes jaro pohybuje.

**Dvě čidla srážek celý rok nic neměřila.** `rain` i `rain_delta` vracejí
po celou dobu nulu. Netvoří 9 % vadných čtení náhodou — jsou to přesně ony.

**Hladinoměr má doloženou poruchu.** 426 čtení vrátilo hodnoty kolem
−280 až −426 cm. Nejde o hodnoty blízké nule, ale o samostatný shluk mimo
rozsah; kdyby se nechaly v datech, model by je četl jako vyschlou tůň
a prohlásil larvy za mrtvé.

**Nejzávažnější omezení: 63 % dnů má teplotu vody dopočítanou.** Hladina
klesla pod nejmělčí čidlo (25 cm) a od té chvíle čidla měřila vzduch, ne
vodu. Model proto teplotu vody dopočítává z teploty vzduchu vztahem
`T_w(t) = T_w(t−1) + 0,29 · (T_a(t) − T_w(t−1))`. Je to obhajitelné, ale
znamená to, že předpověď vývoje larev stojí z větší části na modelu, ne na
měření. V dashboardu je to samostatná míra, ne poznámka pod čarou.

**Na volbě denní agregace záleží víc, než se čekalo.** Pravidlo úhynu
(tři dny pod 2 cm) se vyhodnocuje z denního průměru hladiny. Ten pod práh
neklesl ani jednou, minimum je 2,81 cm. Jednotlivá čtení ale pod prahem
byla — a ve dnech 20.–22. 8. 2023 tři dny po sobě. Kdyby se pravidlo
vyhodnocovalo z denního minima, model by larvy v srpnu 2023 prohlásil za
mrtvé. Pohled `v_low_level_sensitivity` to ukazuje na jednom místě.

---

## Struktura

```
mosprema-bi/
├── data/raw/mosprema206.xlsx     zdrojový export, beze změny
├── etl/
│   ├── build_warehouse.py        ETL: čištění, denní agregace, model vývoje
│   ├── validate.py               27 kontrol nad výstupem
│   ├── build_preview_data.py     data pro náhled v docs/
│   └── requirements.txt
├── out/                          hvězdicové schéma v CSV + protokol běhu
├── postgres/
│   ├── 01_schema.sql             DDL, cizí klíče, indexy
│   ├── 02_load.sql               \copy ze strany klienta
│   ├── 02_load_docker.sql        COPY uvnitř kontejneru
│   ├── 03_views.sql              9 analytických pohledů
│   └── 04_queries.sql            ukázkové dotazy
├── influx/
│   ├── mosprema.lp               line protocol (140 319 řádků)
│   ├── load.ps1 / load.sh        nahrání do bucketu
│   └── flux_queries.flux         ukázkové dotazy ve Fluxu
├── grafana/
│   ├── provisioning/             datové zdroje a poskytovatel dashboardů
│   └── dashboards/               2 dashboardy (24 panelů)
├── powerbi/
│   ├── power_query.m             načtení všech tabulek
│   ├── measures.dax              38 měr s komentáři
│   └── BUILD.md                  postup krok za krokem
├── docs/
│   ├── preview.html              náhled dashboardu (publikovaná stránka)
│   ├── preview.template.html     tentýž soubor bez vložených dat
│   └── preview_data.json         data pro náhled, generuje build_preview_data.py
├── docker-compose.yml
└── start-stack.ps1               rozjede celý stack jedním příkazem
```

---

## Datový model

Hvězda se čtyřmi faktovými tabulkami. Každá má jiné zrno, proto nejde
o jednu širokou tabulku:

| Fakt | Zrno | Řádků |
|---|---|---|
| `fact_reading` | jedno čtení jednoho čidla | 139 791 |
| `fact_daily` | jeden den stanice | 373 |
| `fact_development` | den × druh × model | 528 |
| `fact_gap` | jeden souvislý výpadek | 211 |

Dimenze: `dim_date` (souvislý kalendář, 375 dní), `dim_sensor` (katalog
osmnácti čidel s fyzikálními rozsahy), `dim_species` (parametry Brière-2
z literatury), `dim_model`, `dim_quality`, `dim_station`.

Doménová pravidla v ETL jsou převzatá z modelu bakalářské práce a každá
konstanta má u sebe odkaz na místo, odkud pochází — aby dashboard nezačal
tvrdit něco jiného než text práce:

| Pravidlo | Hodnota | Zdroj |
|---|---|---|
| Práh vyschnutí | 2 cm po 3 dny | `prediction.py` |
| Koeficient výměny tepla | k = 0,29 | fit `temp_1` ~ `temp_air`, únor–březen |
| Hloubka nejmělčího čidla | 25 cm | `prediction.py` |
| Posun náhradní hladiny | +3,30 cm (rozptyl 3,43) | `prediction.py` |
| Hranice instaru 3 a 4 | 40 % a 67 % vývoje | `species.py` |
| Brière-2 parametry | tři druhy | `species.py`, Becker et al., obr. 2.10 |

Jediné pravidlo, které v práci není a přidal ho dashboard: **kohorta
startuje první den od 1. března, kdy teplota vody tři dny po sobě drží nad
`T_base` druhu.** Práce nechává start na uživateli aplikace; dashboard
potřebuje něco reprodukovatelného a stejného pro všechny tři druhy.
Zarážka na 1. březen tam je proto, že bez ní by teplý leden 2024 nastartoval
kohortu *Aedes cantans* uprostřed zimy, kdy druh ještě přezimuje ve
vajíčkách.
