-- =====================================================================
-- Naplnění schématu z CSV vyrobených ETL skriptem (out/).
--
-- \copy běží na straně klienta, takže funguje i proti serveru v kontejneru
-- bez sdíleného disku. Cesty jsou relativní ke složce, ze které psql spouštíš —
-- spouštěj z kořene projektu:
--
--     psql -U mosprema -d mosprema -f postgres/02_load.sql
-- =====================================================================

SET search_path TO mosprema, public;

-- Pořadí respektuje cizí klíče: nejdřív dimenze, pak fakta.
TRUNCATE fact_gap, fact_development, fact_daily, fact_reading,
         dim_model, dim_species, dim_quality, dim_sensor, dim_station, dim_date
         RESTART IDENTITY CASCADE;

\copy dim_date        FROM 'out/dim_date.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy dim_station     FROM 'out/dim_station.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy dim_sensor      FROM 'out/dim_sensor.csv'      WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy dim_quality     FROM 'out/dim_quality.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy dim_species     FROM 'out/dim_species.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy dim_model       FROM 'out/dim_model.csv'       WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\copy fact_reading     FROM 'out/fact_reading.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy fact_daily       FROM 'out/fact_daily.csv'       WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy fact_development FROM 'out/fact_development.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy fact_gap         FROM 'out/fact_gap.csv'         WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

ANALYZE;

-- Kontrola po nahrání: počty musí sedět s protokolem ETL (out/etl_report.md).
SELECT 'dim_date' AS tabulka, count(*) FROM dim_date
UNION ALL SELECT 'dim_sensor',      count(*) FROM dim_sensor
UNION ALL SELECT 'dim_species',     count(*) FROM dim_species
UNION ALL SELECT 'fact_reading',    count(*) FROM fact_reading
UNION ALL SELECT 'fact_daily',      count(*) FROM fact_daily
UNION ALL SELECT 'fact_development', count(*) FROM fact_development
UNION ALL SELECT 'fact_gap',        count(*) FROM fact_gap
ORDER BY 1;
