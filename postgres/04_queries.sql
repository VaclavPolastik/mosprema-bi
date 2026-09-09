-- =====================================================================
-- Ukázkové dotazy
--
-- Nejsou součástí nasazení; jsou tu proto, aby bylo z čeho vycházet,
-- až se někdo zeptá „a co s tím jde zjistit". Každý řeší jednu otázku
-- a používá jednu techniku, kterou se u pohovoru vyplatí umět.
-- =====================================================================

SET search_path TO mosprema, public;


-- ---------------------------------------------------------------------
-- 1. Jak dlouho trvá, než se voda ohřeje za vzduchem?
--    Technika: LAG přes několik zpoždění, korelace.
--
-- Voda má tepelnou setrvačnost — otázka je, o kolik dní.
-- ---------------------------------------------------------------------
WITH posun AS (
    SELECT
        date,
        water_temp_c,
        air_temp_c,
        lag(air_temp_c, 1) OVER (ORDER BY date) AS vzduch_d1,
        lag(air_temp_c, 2) OVER (ORDER BY date) AS vzduch_d2,
        lag(air_temp_c, 3) OVER (ORDER BY date) AS vzduch_d3
    FROM fact_daily
    WHERE water_temp_c IS NOT NULL
      AND NOT water_temp_estimated          -- jen skutečně měřené dny
)
SELECT
    round(corr(water_temp_c, air_temp_c)::numeric, 4) AS bez_posunu,
    round(corr(water_temp_c, vzduch_d1)::numeric, 4)  AS posun_1_den,
    round(corr(water_temp_c, vzduch_d2)::numeric, 4)  AS posun_2_dny,
    round(corr(water_temp_c, vzduch_d3)::numeric, 4)  AS posun_3_dny
FROM posun;


-- ---------------------------------------------------------------------
-- 2. Denní chod teploty v jednotlivých měsících
--    Technika: pivot přes FILTER, agregace po hodinách.
--
-- Ukazuje, jak se přes léto rozevírá rozdíl mezi dnem a nocí.
-- ---------------------------------------------------------------------
SELECT
    extract(hour FROM r.ts_local)::int AS hodina,
    round(avg(r.value) FILTER (WHERE d.month = 4), 1) AS duben,
    round(avg(r.value) FILTER (WHERE d.month = 6), 1) AS cerven,
    round(avg(r.value) FILTER (WHERE d.month = 8), 1) AS srpen,
    round(avg(r.value) FILTER (WHERE d.month = 10), 1) AS rijen
FROM fact_reading r
JOIN dim_date d ON d.date_key = r.date_key
WHERE r.sensor_key = 'temp_1' AND r.quality_key = 'OK'
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 3. Kolik dnů uběhne mezi překročením prahů jednotlivých instarů
--    Technika: podmíněná agregace nad kumulativní řadou.
-- ---------------------------------------------------------------------
SELECT
    sp.species_label,
    v.model_key,
    min(v.date)                                            AS start,
    min(v.date) FILTER (WHERE v.pct_complete >= 40)        AS instar_3,
    min(v.date) FILTER (WHERE v.pct_complete >= 67)        AS instar_4,
    min(v.date) FILTER (WHERE v.pct_complete >= 100)       AS kukleni,
    min(v.date) FILTER (WHERE v.pct_complete >= 100)
  - min(v.date)                                            AS celkem_dnu
FROM fact_development v
JOIN dim_species sp ON sp.species_key = v.species_key
GROUP BY sp.species_label, v.model_key, v.cohort_id
ORDER BY sp.species_label, v.model_key;


-- ---------------------------------------------------------------------
-- 4. Kdy stanice vypadla a co tomu předcházelo
--    Technika: LATERAL join — pro každý výpadek se dotáhne stav
--    stanice v hodinách těsně před ním.
-- ---------------------------------------------------------------------
SELECT
    g.gap_start,
    g.missing_hours,
    g.severity,
    round(pred.prum_signal, 1)   AS signal_pred_vypadkem,
    round(pred.prum_baterie, 0)  AS baterie_pred_vypadkem
FROM fact_gap g
CROSS JOIN LATERAL (
    SELECT
        avg(r.value) FILTER (WHERE r.sensor_key = 'signal') AS prum_signal,
        avg(r.value) FILTER (WHERE r.sensor_key = 'bat')    AS prum_baterie
    FROM fact_reading r
    WHERE r.ts_local BETWEEN g.gap_start - interval '6 hours' AND g.gap_start
      AND r.quality_key = 'OK'
) pred
WHERE g.missing_hours >= 6
ORDER BY g.missing_hours DESC;


-- ---------------------------------------------------------------------
-- 5. Které dny by model vyhodnotil jinak, kdyby se hladina nenahrazovala
--    Technika: porovnání dvou variant výpočtu nad týmiž daty.
--
-- Náhrada dist_rel + 3,30 cm má rozptyl 3,43 cm — víc než dvoucentimetrový
-- práh vyschnutí. Tenhle dotaz najde dny, kde na tom rozdílu záleží.
-- ---------------------------------------------------------------------
SELECT
    date,
    round(water_level_cm, 2)        AS hladina_pouzita,
    round(water_level_cm - 3.30, 2) AS hladina_bez_offsetu,
    level_substituted,
    CASE
        WHEN water_level_cm >= 2.0 AND water_level_cm - 3.30 < 2.0
            THEN 'rozhodnutí závisí na offsetu'
        ELSE 'bez vlivu'
    END AS dopad
FROM fact_daily
WHERE level_substituted
  AND water_level_cm < 10
ORDER BY water_level_cm;


-- ---------------------------------------------------------------------
-- 6. Přehled pro jeden řádek do prezentace
-- ---------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM fact_reading)                                    AS cteni,
    (SELECT count(*) FROM fact_daily)                                      AS dnu,
    (SELECT round(100.0 * count(*) FILTER (WHERE quality_key = 'OK')
                  / count(*), 1) FROM fact_reading)                        AS platnych_pct,
    (SELECT round(100.0 * count(*) FILTER (WHERE water_temp_estimated)
                  / count(*), 1) FROM fact_daily)                          AS dopoctenych_dnu_pct,
    (SELECT sum(missing_hours) FROM fact_gap)                              AS chybejicich_hodin,
    (SELECT min(date) FROM fact_daily)                                     AS od,
    (SELECT max(date) FROM fact_daily)                                     AS do_dne;
