-- =====================================================================
-- Nahrání dat uvnitř kontejneru.
--
-- Rozdíl proti 02_load.sql: tam se používá klientské \copy, tady serverové
-- COPY, protože docker-compose připojuje složku out/ přímo do kontejneru
-- jako /csv. Server tedy soubory vidí a čte je sám.
--
-- Skript pouští Postgres automaticky při prvním startu prázdného svazku.
-- =====================================================================

SET search_path TO mosprema, public;

COPY dim_date        FROM '/csv/dim_date.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY dim_station     FROM '/csv/dim_station.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY dim_sensor      FROM '/csv/dim_sensor.csv'      WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY dim_quality     FROM '/csv/dim_quality.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY dim_species     FROM '/csv/dim_species.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY dim_model       FROM '/csv/dim_model.csv'       WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY fact_reading     FROM '/csv/fact_reading.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY fact_daily       FROM '/csv/fact_daily.csv'       WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY fact_development FROM '/csv/fact_development.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY fact_gap         FROM '/csv/fact_gap.csv'         WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

ANALYZE;
