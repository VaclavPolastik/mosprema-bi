-- =====================================================================
-- mosprema_206 — hvězdicové schéma pro data z bakalářské práce
-- PostgreSQL 14+
--
-- Spuštění:  psql -U postgres -f 01_schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS mosprema CASCADE;
CREATE SCHEMA mosprema;
SET search_path TO mosprema, public;

COMMENT ON SCHEMA mosprema IS
  'Telemetrie stanice mosprema_206 (tůň v lužním lese) a model vývoje komářích larev. '
  'Zdroj: bakalářská práce V. Polaštíka, Univerzita Palackého v Olomouci.';

-- ---------------------------------------------------------------------
-- DIMENZE
-- ---------------------------------------------------------------------

CREATE TABLE dim_date (
    date_key          integer PRIMARY KEY,          -- YYYYMMDD
    date              date        NOT NULL UNIQUE,
    year              smallint    NOT NULL,
    quarter           smallint    NOT NULL,
    month             smallint    NOT NULL,
    month_name        text        NOT NULL,
    month_short       text        NOT NULL,
    year_month        char(7)     NOT NULL,
    day               smallint    NOT NULL,
    day_of_year       smallint    NOT NULL,
    iso_week          smallint    NOT NULL,
    weekday           smallint    NOT NULL,          -- 1 = pondělí
    weekday_name      text        NOT NULL,
    weekday_short     text        NOT NULL,
    is_weekend        boolean     NOT NULL,
    season            text        NOT NULL,
    is_growing_season boolean     NOT NULL           -- duben–září
);
COMMENT ON TABLE dim_date IS 'Souvislá kalendářní osa; je souvislá i tam, kde stanice neměřila.';

CREATE TABLE dim_station (
    station_id    integer PRIMARY KEY,
    station_name  text NOT NULL,
    latitude      numeric(9,6),
    longitude     numeric(9,6),
    locality      text,
    first_reading timestamp,
    last_reading  timestamp
);

CREATE TABLE dim_sensor (
    sensor_key   text PRIMARY KEY,
    sensor_label text NOT NULL,
    category     text NOT NULL,          -- Teplota / Hladina / Atmosféra / Technika
    unit         text NOT NULL,
    depth_cm     numeric(6,2),           -- hloubka čidla pod hladinou, jen u temp_1..3
    min_valid    numeric(10,2) NOT NULL, -- fyzikální rozsah, podklad pro příznak jakosti
    max_valid    numeric(10,2) NOT NULL,
    is_core      boolean NOT NULL        -- vstupuje do modelu vývoje
);

CREATE TABLE dim_quality (
    quality_key  text PRIMARY KEY,
    quality_label text NOT NULL,
    quality_note  text,
    severity      smallint NOT NULL      -- 0 = v pořádku, výš = horší
);

CREATE TABLE dim_species (
    species_key    text PRIMARY KEY,
    species_label  text NOT NULL,
    briere_t0      numeric(6,3) NOT NULL,   -- tvarový parametr Brière-2
    briere_tm      numeric(6,3) NOT NULL,
    briere_a       numeric(12,10) NOT NULL,
    briere_m       numeric(4,2) NOT NULL,
    t_base_c       numeric(5,2) NOT NULL,   -- publikovaný dolní práh vývoje
    dd_instar4     integer NOT NULL,        -- °D do instaru 4 (test konstantních teplot)
    tm_is_measured boolean NOT NULL,        -- je horní práh doložen daty, nebo je to předpoklad?
    note           text,
    dd_total       numeric(8,2) NOT NULL,   -- °D do kuklení (dopočet z prahu instaru 4)
    dd_stage2      numeric(8,2) NOT NULL,
    dd_stage3      numeric(8,2) NOT NULL,
    source         text
);
COMMENT ON COLUMN dim_species.briere_t0 IS
  'Tvarový parametr fitované křivky, NE publikovaný práh vývoje — ten je v t_base_c.';

CREATE TABLE dim_model (
    model_key   text PRIMARY KEY,
    model_label text NOT NULL,
    model_note  text,
    unit        text NOT NULL
);

-- ---------------------------------------------------------------------
-- FAKTA
-- ---------------------------------------------------------------------

-- Zrno: jedno čtení jednoho čidla. Dlouhý formát je ponechán schválně —
-- stanice může kdykoli dostat další veličinu, aniž by se měnilo schéma.
CREATE TABLE fact_reading (
    date_key    integer NOT NULL REFERENCES dim_date(date_key),
    ts_local    timestamp NOT NULL,
    ts_utc      timestamptz NOT NULL,
    station_id  integer NOT NULL REFERENCES dim_station(station_id),
    sensor_key  text NOT NULL REFERENCES dim_sensor(sensor_key),
    quality_key text NOT NULL REFERENCES dim_quality(quality_key),
    value       numeric(12,4),
    PRIMARY KEY (station_id, ts_local, sensor_key)
);

-- Zrno: jeden den stanice. Denní agregace už nese doménová pravidla práce
-- (výběr čidla podle hloubky, náhrada hladiny, dopočet teploty nad hladinou).
CREATE TABLE fact_daily (
    date_key             integer PRIMARY KEY REFERENCES dim_date(date_key),
    date                 date NOT NULL,
    station_id           integer NOT NULL REFERENCES dim_station(station_id),
    n_readings           smallint NOT NULL,
    expected_readings    smallint NOT NULL,
    coverage_pct         numeric(5,1) NOT NULL,
    water_temp_c         numeric(6,3),
    water_temp_min_c     numeric(6,3),
    water_temp_max_c     numeric(6,3),
    water_temp_estimated boolean NOT NULL,   -- teplota dopočtena, čidla byla nad hladinou
    submerged_sensor     text,               -- které čidlo bylo pod vodou
    air_temp_c           numeric(6,3),
    air_temp_min_c       numeric(6,3),
    air_temp_max_c       numeric(6,3),
    water_level_cm       numeric(8,3),
    water_level_min_cm   numeric(8,3),
    low_level_readings   smallint NOT NULL,  -- kolik čtení za den bylo pod 2 cm
    level_substituted    boolean NOT NULL,   -- hladina z dist_rel + offset
    air_hum_pct          numeric(6,3),
    soil_temp_c          numeric(6,3),
    soil_hum_pct         numeric(6,3),
    battery_mv           numeric(8,2),
    signal_dbm           numeric(8,2)
);

-- Zrno: den × kohorta × model.
CREATE TABLE fact_development (
    date_key          integer NOT NULL REFERENCES dim_date(date_key),
    date              date NOT NULL,
    station_id        integer NOT NULL REFERENCES dim_station(station_id),
    cohort_id         text NOT NULL,
    species_key       text NOT NULL REFERENCES dim_species(species_key),
    model_key         text NOT NULL REFERENCES dim_model(model_key),
    water_temp_c      numeric(6,3),
    daily_step        numeric(12,6) NOT NULL,  -- přírůstek dne (°D nebo podíl)
    cumulative        numeric(12,6) NOT NULL,
    target            numeric(12,2) NOT NULL,  -- hodnota odpovídající 100 %
    unit              text NOT NULL,
    pct_complete      numeric(7,3) NOT NULL,
    stage             text NOT NULL,
    is_dead           boolean NOT NULL,
    is_complete       boolean NOT NULL,
    temp_estimated    boolean NOT NULL,
    level_substituted boolean NOT NULL,
    PRIMARY KEY (cohort_id, model_key, date)
);

-- Zrno: jeden souvislý výpadek měření.
CREATE TABLE fact_gap (
    gap_id        integer PRIMARY KEY,
    date          date NOT NULL,
    gap_start     timestamp NOT NULL,
    gap_end       timestamp NOT NULL,
    missing_hours integer NOT NULL,
    severity      text NOT NULL,
    station_id    integer NOT NULL REFERENCES dim_station(station_id),
    date_key      integer NOT NULL REFERENCES dim_date(date_key)
);

-- ---------------------------------------------------------------------
-- INDEXY
-- Volba vychází z toho, jak se na tabulky ptá dashboard: skoro vždy
-- „časové okno + jedno čidlo“, případně „časové okno + jedna jakost“.
-- ---------------------------------------------------------------------
CREATE INDEX ix_reading_sensor_ts ON fact_reading (sensor_key, ts_local);
CREATE INDEX ix_reading_ts        ON fact_reading (ts_local);
CREATE INDEX ix_reading_quality   ON fact_reading (quality_key) WHERE quality_key <> 'OK';
CREATE INDEX ix_daily_date        ON fact_daily (date);
CREATE INDEX ix_dev_species_date  ON fact_development (species_key, model_key, date);
CREATE INDEX ix_gap_start         ON fact_gap (gap_start);
