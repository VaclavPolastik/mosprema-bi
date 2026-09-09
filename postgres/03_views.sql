-- =====================================================================
-- Analytické pohledy
--
-- Pohledy jsou napsané tak, aby na ně mohla sáhnout Grafana i Power BI
-- (DirectQuery) bez dalšího přepočítávání na straně klienta.
-- =====================================================================

SET search_path TO mosprema, public;

-- ---------------------------------------------------------------------
-- 1. Denní přehled s klouzavými průměry
--    Klouzavý průměr za 7 dní tlumí denní výkyvy; ve vodě s malým objemem
--    kolísá teplota mezi dnem a nocí natolik, že by holá denní řada
--    v grafu překryla sezónní trend.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_daily_enriched CASCADE;
CREATE VIEW v_daily_enriched AS
SELECT
    f.date_key,
    f.date,
    d.year,
    d.month,
    d.month_name,
    d.year_month,
    d.iso_week,
    d.season,
    d.is_growing_season,
    f.water_temp_c,
    f.air_temp_c,
    f.water_level_cm,
    f.coverage_pct,
    f.water_temp_estimated,
    f.level_substituted,
    f.submerged_sensor,
    round(avg(f.water_temp_c) OVER w7, 2)                       AS water_temp_ma7,
    round(avg(f.air_temp_c)   OVER w7, 2)                       AS air_temp_ma7,
    round(avg(f.water_level_cm) OVER w7, 2)                     AS water_level_ma7,
    round(f.water_temp_c - f.air_temp_c, 2)                     AS temp_diff_water_air,
    round(f.water_temp_c - lag(f.water_temp_c) OVER (ORDER BY f.date), 2)
                                                                AS water_temp_delta_1d,
    round(f.water_level_cm - lag(f.water_level_cm) OVER (ORDER BY f.date), 2)
                                                                AS water_level_delta_1d
FROM fact_daily f
JOIN dim_date d ON d.date_key = f.date_key
WINDOW w7 AS (ORDER BY f.date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW);

COMMENT ON VIEW v_daily_enriched IS
  'Denní řada doplněná o klouzavé průměry a denní přírůstky. Základ časových grafů.';


-- ---------------------------------------------------------------------
-- 2. Jakost dat po čidlech
--    Odpovídá na otázku, které z osmnácti veličin se dá věřit.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_data_quality CASCADE;
CREATE VIEW v_data_quality AS
SELECT
    s.sensor_key,
    s.sensor_label,
    s.category,
    s.unit,
    s.is_core,
    count(*)                                                    AS readings,
    count(*) FILTER (WHERE r.quality_key = 'OK')                AS ok_readings,
    count(*) FILTER (WHERE r.quality_key <> 'OK')               AS bad_readings,
    round(100.0 * count(*) FILTER (WHERE r.quality_key = 'OK') / count(*), 2)
                                                                AS ok_pct,
    count(DISTINCT r.value)                                     AS distinct_values,
    min(r.value)                                                AS min_value,
    max(r.value)                                                AS max_value,
    round(avg(r.value) FILTER (WHERE r.quality_key = 'OK'), 3)  AS avg_ok_value,
    -- nejčastější důvod vyřazení, ať je hned vidět, o jakou poruchu jde
    mode() WITHIN GROUP (ORDER BY r.quality_key)
        FILTER (WHERE r.quality_key <> 'OK')                    AS worst_flag,
    min(r.ts_local)                                             AS first_reading,
    max(r.ts_local)                                             AS last_reading
FROM fact_reading r
JOIN dim_sensor s ON s.sensor_key = r.sensor_key
GROUP BY s.sensor_key, s.sensor_label, s.category, s.unit, s.is_core;

COMMENT ON VIEW v_data_quality IS
  'Přehled jakosti po čidlech. distinct_values = 1 znamená čidlo, které neměří (rain, rain_delta).';


-- ---------------------------------------------------------------------
-- 3. Měsíční pokrytí měření
--    Spojuje skutečná měření s výpadky; měsíc bez měření se v pohledu
--    objeví taky, protože se vychází z kalendáře, ne z faktů.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_coverage_monthly CASCADE;
CREATE VIEW v_coverage_monthly AS
WITH kalendar AS (
    SELECT year_month, count(*) AS days_in_period
    FROM dim_date
    GROUP BY year_month
),
mereni AS (
    SELECT d.year_month,
           count(*)                       AS days_measured,
           sum(f.n_readings)              AS readings,
           round(avg(f.coverage_pct), 1)  AS avg_coverage_pct
    FROM fact_daily f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_month
),
vypadky AS (
    SELECT d.year_month,
           count(*)            AS gap_blocks,
           sum(g.missing_hours) AS missing_hours
    FROM fact_gap g
    JOIN dim_date d ON d.date_key = g.date_key
    GROUP BY d.year_month
)
SELECT
    k.year_month,
    k.days_in_period,
    coalesce(m.days_measured, 0)      AS days_measured,
    coalesce(m.readings, 0)           AS readings,
    m.avg_coverage_pct,
    coalesce(v.gap_blocks, 0)         AS gap_blocks,
    coalesce(v.missing_hours, 0)      AS missing_hours,
    round(100.0 * (k.days_in_period * 24 - coalesce(v.missing_hours, 0))
          / (k.days_in_period * 24), 1) AS uptime_pct
FROM kalendar k
LEFT JOIN mereni  m ON m.year_month = k.year_month
LEFT JOIN vypadky v ON v.year_month = k.year_month;


-- ---------------------------------------------------------------------
-- 4. Souvislé úseky nízké hladiny (gaps and islands)
--    Přesně to pravidlo, na kterém stojí model: tři dny pod 2 cm =
--    tůň vyschla a larvy hynou. Tady je zapsané čistě v SQL.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_water_level_runs CASCADE;
CREATE VIEW v_water_level_runs AS
WITH oznaceni AS (
    SELECT
        date,
        water_level_cm,
        (water_level_cm < 2.0) AS is_low,
        -- rozdíl dvou řad pořadí je konstantní uvnitř souvislého úseku
        row_number() OVER (ORDER BY date)
      - row_number() OVER (PARTITION BY (water_level_cm < 2.0) ORDER BY date) AS island
    FROM fact_daily
    WHERE water_level_cm IS NOT NULL
)
SELECT
    is_low,
    min(date)                    AS od,
    -- Sloupec se schvalne nejmenuje "do": to je v PostgreSQL rezervovane slovo.
    -- Jako alias v CREATE VIEW projde, ale SELECT do, ... z takoveho pohledu
    -- pak spadne na syntakticke chybe.
    max(date)                    AS do_dne,
    count(*)                     AS dnu,
    round(min(water_level_cm), 1) AS min_hladina_cm,
    round(avg(water_level_cm), 1) AS prum_hladina_cm,
    (is_low AND count(*) >= 3)   AS splnuje_pravidlo_uhynu
FROM oznaceni
GROUP BY is_low, island
ORDER BY od;

COMMENT ON VIEW v_water_level_runs IS
  'Souvislé úseky nad/pod 2 cm. splnuje_pravidlo_uhynu = úsek, po kterém by model prohlásil larvy za mrtvé.';


-- ---------------------------------------------------------------------
-- 5. Shrnutí kohort a porovnání obou modelů
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_development_summary CASCADE;
CREATE VIEW v_development_summary AS
SELECT
    v.cohort_id,
    v.species_key,
    sp.species_label,
    v.model_key,
    m.model_label,
    min(v.date)                                          AS start_date,
    max(v.date)                                          AS end_date,
    count(*)                                             AS dnu_vyvoje,
    max(v.pct_complete)                                  AS max_pct,
    bool_or(v.is_complete)                               AS doslo_ke_kukleni,
    min(v.date) FILTER (WHERE v.is_complete)             AS datum_kukleni,
    bool_or(v.is_dead)                                   AS larvy_uhynuly,
    round(avg(v.water_temp_c), 2)                        AS prum_teplota_vody,
    count(*) FILTER (WHERE v.temp_estimated)             AS dnu_s_odhadnutou_teplotou,
    round(100.0 * count(*) FILTER (WHERE v.temp_estimated) / count(*), 1)
                                                         AS podil_odhadnutych_pct
FROM fact_development v
JOIN dim_species sp ON sp.species_key = v.species_key
JOIN dim_model   m  ON m.model_key    = v.model_key
GROUP BY v.cohort_id, v.species_key, sp.species_label, v.model_key, m.model_label;


-- ---------------------------------------------------------------------
-- 6. O kolik dní se modely rozcházejí
--    Hlavní zjištění dashboardu: nelineární model dojde ke kuklení dřív.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_model_comparison CASCADE;
CREATE VIEW v_model_comparison AS
SELECT
    cohort_id,
    species_label,
    max(start_date)                                            AS start_kohorty,
    max(datum_kukleni) FILTER (WHERE model_key = 'zakladni')   AS kukleni_zakladni,
    max(datum_kukleni) FILTER (WHERE model_key = 'pokrocily')  AS kukleni_pokrocily,
    max(dnu_vyvoje)    FILTER (WHERE model_key = 'zakladni')   AS dnu_zakladni,
    max(dnu_vyvoje)    FILTER (WHERE model_key = 'pokrocily')  AS dnu_pokrocily,
    max(dnu_vyvoje)    FILTER (WHERE model_key = 'zakladni')
  - max(dnu_vyvoje)    FILTER (WHERE model_key = 'pokrocily')  AS rozdil_dnu
FROM v_development_summary
GROUP BY cohort_id, species_label
ORDER BY cohort_id;


-- ---------------------------------------------------------------------
-- 7. Denní řada po čidlech (dlouhý formát pro Grafanu)
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_sensor_daily CASCADE;
CREATE VIEW v_sensor_daily AS
SELECT
    r.ts_local::date            AS date,
    s.sensor_key,
    s.sensor_label,
    s.category,
    s.unit,
    count(*)                    AS readings,
    round(avg(r.value), 3)      AS avg_value,
    min(r.value)                AS min_value,
    max(r.value)                AS max_value
FROM fact_reading r
JOIN dim_sensor s ON s.sensor_key = r.sensor_key
WHERE r.quality_key = 'OK'
GROUP BY 1, 2, 3, 4, 5;


-- ---------------------------------------------------------------------
-- 8. Citlivost pravidla úhynu na volbu denní agregace
--
--    Model bakalářské práce vyhodnocuje pravidlo „tři dny pod 2 cm"
--    z denního průměru hladiny. Ten pod práh neklesl nikdy (minimum
--    2,81 cm). Jednotlivá čtení ale pod prahem byla, a to i tři dny
--    po sobě (20.–22. 8. 2023). Volba agregace tedy rozhoduje o tom,
--    jestli model larvy prohlásí za mrtvé, nebo ne — a tenhle pohled
--    to má ukázat, ne schovat.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_low_level_sensitivity CASCADE;
CREATE VIEW v_low_level_sensitivity AS
WITH oznaceni AS (
    SELECT
        date,
        water_level_cm,
        water_level_min_cm,
        low_level_readings,
        (low_level_readings > 0) AS ma_cteni_pod_prahem,
        row_number() OVER (ORDER BY date)
      - row_number() OVER (PARTITION BY (low_level_readings > 0) ORDER BY date) AS island
    FROM fact_daily
    WHERE water_level_cm IS NOT NULL
)
SELECT
    ma_cteni_pod_prahem,
    min(date)                          AS od,
    max(date)                          AS do_dne,
    count(*)                           AS dnu,
    sum(low_level_readings)            AS cteni_pod_prahem,
    round(min(water_level_min_cm), 2)  AS nejnizsi_cteni_cm,
    round(min(water_level_cm), 2)      AS nejnizsi_denni_prumer_cm,
    (ma_cteni_pod_prahem AND count(*) >= 3) AS spustilo_by_pravidlo
FROM oznaceni
GROUP BY ma_cteni_pod_prahem, island
ORDER BY od;


-- ---------------------------------------------------------------------
-- 9. Dny, kdy se voda chovala jinak než vzduch
--     Velký rozdíl mezi vodou a vzduchem obvykle znamená, že čidlo
--     vyčnívalo nad hladinu a svítilo na něj slunce.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_thermal_anomaly CASCADE;
CREATE VIEW v_thermal_anomaly AS
SELECT
    date,
    water_temp_c,
    air_temp_c,
    round(water_temp_c - air_temp_c, 2) AS rozdil,
    water_level_cm,
    water_temp_estimated,
    CASE
        WHEN water_temp_c - air_temp_c >  5 THEN 'voda výrazně teplejší'
        WHEN water_temp_c - air_temp_c < -5 THEN 'voda výrazně chladnější'
        ELSE 'v normě'
    END AS hodnoceni
FROM fact_daily
WHERE water_temp_c IS NOT NULL AND air_temp_c IS NOT NULL;
