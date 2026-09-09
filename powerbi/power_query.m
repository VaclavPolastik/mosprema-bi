// =====================================================================
// Power Query (jazyk M) — načtení hvězdicového schématu z out/*.csv
//
// Jak to použít
// -------------
// 1. V Power BI Desktopu: Transformovat data → Správce parametrů →
//    Nový parametr „SlozkaDat" typu Text, hodnota = cesta ke složce out.
// 2. Pro každý blok níže: Nový zdroj → Prázdný dotaz → Rozšířený editor →
//    vložit kód → pojmenovat dotaz stejně jako nadpis bloku.
//
// Proč je u každého převodu typu uvedeno "en-US"
// ----------------------------------------------
// CSV z ETL má desetinnou tečku a datum ve tvaru RRRR-MM-DD. Na českém
// Windows je výchozí locale cs-CZ s desetinnou čárkou, takže bez uvedené
// kultury by se 6.09 načetlo jako chyba nebo jako 609. Tohle je nejčastější
// důvod, proč „to samé CSV" funguje jednomu a druhému ne.
// =====================================================================


// ---------------------------------------------------------------------
// SlozkaDat  (parametr, ne dotaz — zakládá se ve Správci parametrů)
// ---------------------------------------------------------------------
// Hodnota např.:  C:\Users\PC\Desktop\pohovor\mosprema-bi\out


// ---------------------------------------------------------------------
// fnNacti  (pomocná funkce — načte CSV a povýší hlavičku)
// ---------------------------------------------------------------------
let
    fnNacti = (nazevSouboru as text) as table =>
        let
            Zdroj = Csv.Document(
                File.Contents(SlozkaDat & "\" & nazevSouboru),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
            ),
            // Encoding 65001 = UTF-8. Bez toho se české popisky rozsypou.
            Hlavicka = Table.PromoteHeaders(Zdroj, [PromoteAllScalars = true])
        in
            Hlavicka
in
    fnNacti


// ---------------------------------------------------------------------
// dim_date
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_date.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"date_key", Int64.Type},
        {"date", type date},
        {"year", Int64.Type},
        {"quarter", Int64.Type},
        {"month", Int64.Type},
        {"month_name", type text},
        {"month_short", type text},
        {"year_month", type text},
        {"day", Int64.Type},
        {"day_of_year", Int64.Type},
        {"iso_week", Int64.Type},
        {"weekday", Int64.Type},
        {"weekday_name", type text},
        {"weekday_short", type text},
        {"is_weekend", type logical},
        {"season", type text},
        {"is_growing_season", type logical}
    }, "en-US"),
    // Řadicí sloupce: bez nich by se měsíce v grafu seřadily abecedně
    // (březen, duben, červen…), což je pro časovou osu nepoužitelné.
    SRadicimi = Table.AddColumn(Typy, "month_sort", each [month], Int64.Type),
    SRadicimi2 = Table.AddColumn(SRadicimi, "weekday_sort", each [weekday], Int64.Type)
in
    SRadicimi2


// ---------------------------------------------------------------------
// dim_sensor
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_sensor.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"sensor_key", type text},
        {"sensor_label", type text},
        {"category", type text},
        {"unit", type text},
        {"depth_cm", type number},
        {"min_valid", type number},
        {"max_valid", type number},
        {"is_core", type logical}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// dim_station
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_station.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"station_id", Int64.Type},
        {"station_name", type text},
        {"latitude", type number},
        {"longitude", type number},
        {"locality", type text},
        {"first_reading", type datetime},
        {"last_reading", type datetime}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// dim_species
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_species.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"species_key", type text},
        {"species_label", type text},
        {"briere_t0", type number},
        {"briere_tm", type number},
        {"briere_a", type number},
        {"briere_m", type number},
        {"t_base_c", type number},
        {"dd_instar4", Int64.Type},
        {"tm_is_measured", type logical},
        {"note", type text},
        {"dd_total", type number},
        {"dd_stage2", type number},
        {"dd_stage3", type number},
        {"source", type text}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// dim_model
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_model.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"model_key", type text},
        {"model_label", type text},
        {"model_note", type text},
        {"unit", type text}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// dim_quality
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("dim_quality.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"quality_key", type text},
        {"quality_label", type text},
        {"quality_note", type text},
        {"severity", Int64.Type}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// fact_reading  (139 791 řádků)
//
// Sloupec ts_utc se schválně nenačítá: nese tutéž informaci jako ts_local,
// jen v jiné zóně, a v modelu by jen zabíral místo. Kdyby stanic přibylo
// víc v různých zónách, vrátil by se.
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("fact_reading.csv"),
    Vybrane = Table.SelectColumns(Zdroj,
        {"date_key", "ts_local", "station_id", "sensor_key", "quality_key", "value"}),
    Typy = Table.TransformColumnTypes(Vybrane, {
        {"date_key", Int64.Type},
        {"ts_local", type datetime},
        {"station_id", Int64.Type},
        {"sensor_key", type text},
        {"quality_key", type text},
        {"value", type number}
    }, "en-US"),
    // Hodina zvlášť kvůli profilu denního chodu teploty
    SHodinou = Table.AddColumn(Typy, "hour", each Time.Hour([ts_local]), Int64.Type)
in
    SHodinou


// ---------------------------------------------------------------------
// fact_daily
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("fact_daily.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"date_key", Int64.Type},
        {"date", type date},
        {"station_id", Int64.Type},
        {"n_readings", Int64.Type},
        {"expected_readings", Int64.Type},
        {"coverage_pct", type number},
        {"water_temp_c", type number},
        {"water_temp_min_c", type number},
        {"water_temp_max_c", type number},
        {"water_temp_estimated", type logical},
        {"submerged_sensor", type text},
        {"air_temp_c", type number},
        {"air_temp_min_c", type number},
        {"air_temp_max_c", type number},
        {"water_level_cm", type number},
        {"water_level_min_cm", type number},
        {"level_substituted", type logical},
        {"air_hum_pct", type number},
        {"soil_temp_c", type number},
        {"soil_hum_pct", type number},
        {"battery_mv", type number},
        {"signal_dbm", type number}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// fact_development
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("fact_development.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"date_key", Int64.Type},
        {"date", type date},
        {"station_id", Int64.Type},
        {"cohort_id", type text},
        {"species_key", type text},
        {"model_key", type text},
        {"water_temp_c", type number},
        {"daily_step", type number},
        {"cumulative", type number},
        {"target", type number},
        {"unit", type text},
        {"pct_complete", type number},
        {"stage", type text},
        {"is_dead", type logical},
        {"is_complete", type logical},
        {"temp_estimated", type logical},
        {"level_substituted", type logical}
    }, "en-US"),
    // Řadicí sloupec pro fáze vývoje — jinak by se v legendě seřadily abecedně
    SRazenim = Table.AddColumn(Typy, "stage_sort", each
        if [stage] = "instar 1–2" then 1
        else if [stage] = "instar 3" then 2
        else if [stage] = "instar 4" then 3
        else if [stage] = "kukleni" then 4
        else 5, Int64.Type)
in
    SRazenim


// ---------------------------------------------------------------------
// fact_gap
// ---------------------------------------------------------------------
let
    Zdroj = fnNacti("fact_gap.csv"),
    Typy = Table.TransformColumnTypes(Zdroj, {
        {"gap_id", Int64.Type},
        {"date", type date},
        {"gap_start", type datetime},
        {"gap_end", type datetime},
        {"missing_hours", Int64.Type},
        {"severity", type text},
        {"station_id", Int64.Type},
        {"date_key", Int64.Type}
    }, "en-US")
in
    Typy


// ---------------------------------------------------------------------
// Míry  (prázdná tabulka, do které se sesypou všechny míry)
//
// Trik: tabulka bez sloupců se v seznamu polí zobrazí jako složka s mírami
// nahoře. Bez ní se míry rozlézají po faktových tabulkách a model
// se špatně čte.
// ---------------------------------------------------------------------
let
    Zdroj = Table.FromRows({}, type table [Placeholder = text])
in
    Zdroj
