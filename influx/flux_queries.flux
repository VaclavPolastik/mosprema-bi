// =====================================================================
// Ukázkové dotazy ve Fluxu
//
// Spustit se dají ve webovém rozhraní InfluxDB (http://localhost:8086,
// záložka Data Explorer → Script Editor) nebo přes CLI:
//
//     docker compose exec influxdb influx query --org upol --token <token> "<dotaz>"
//
// Flux se čte odshora dolů jako roura: každé |> dostane tabulku
// a vrátí tabulku. Nejbližší analogie je metodový řetězec v pandas.
// =====================================================================


// ---------------------------------------------------------------------
// 1. Denní průměr teploty vody
// ---------------------------------------------------------------------
from(bucket: "mosprema")
    |> range(start: 2023-03-15T00:00:00Z, stop: 2024-03-24T00:00:00Z)
    |> filter(fn: (r) => r._measurement == "sensor_reading")
    |> filter(fn: (r) => r.sensor == "temp_1" and r.quality == "OK")
    |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
    |> yield(name: "denni_prumer")


// ---------------------------------------------------------------------
// 2. Rozdíl mezi vodou a vzduchem
//    Dvě řady se musí nejdřív srovnat na společnou časovou mřížku,
//    teprve pak se dají odečíst — join sám o sobě nestačí, protože
//    čtení nechodí přesně ve stejnou vteřinu.
// ---------------------------------------------------------------------
voda =
    from(bucket: "mosprema")
        |> range(start: 2023-03-15T00:00:00Z, stop: 2024-03-24T00:00:00Z)
        |> filter(fn: (r) => r._measurement == "sensor_reading" and r.sensor == "temp_1" and r.quality == "OK")
        |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
        |> keep(columns: ["_time", "_value"])
        |> rename(columns: {_value: "voda"})

vzduch =
    from(bucket: "mosprema")
        |> range(start: 2023-03-15T00:00:00Z, stop: 2024-03-24T00:00:00Z)
        |> filter(fn: (r) => r._measurement == "sensor_reading" and r.sensor == "temp_air" and r.quality == "OK")
        |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
        |> keep(columns: ["_time", "_value"])
        |> rename(columns: {_value: "vzduch"})

join(tables: {v: voda, a: vzduch}, on: ["_time"])
    |> map(fn: (r) => ({_time: r._time, _value: r.voda - r.vzduch}))
    |> yield(name: "rozdil_voda_vzduch")


// ---------------------------------------------------------------------
// 3. Kolik čtení má která jakost
//    Rychlá kontrola, že se do bucketu dostaly i vadné hodnoty
//    s příznakem, ne jen ty dobré.
// ---------------------------------------------------------------------
from(bucket: "mosprema")
    |> range(start: 2023-01-01T00:00:00Z, stop: 2025-01-01T00:00:00Z)
    |> filter(fn: (r) => r._measurement == "sensor_reading")
    |> group(columns: ["quality"])
    |> count()
    |> yield(name: "jakost")


// ---------------------------------------------------------------------
// 4. Hladina pod prahem vyschnutí
//    Vrací čtení, při kterých byla tůň prakticky vyschlá.
// ---------------------------------------------------------------------
from(bucket: "mosprema")
    |> range(start: 2023-03-15T00:00:00Z, stop: 2024-03-24T00:00:00Z)
    |> filter(fn: (r) => r._measurement == "sensor_reading")
    |> filter(fn: (r) => r.sensor == "dist_comp_rel" and r.quality == "OK")
    |> filter(fn: (r) => r._value < 2.0)
    |> yield(name: "vyschla_tun")


// ---------------------------------------------------------------------
// 5. Vývoj larev podle druhu
// ---------------------------------------------------------------------
from(bucket: "mosprema")
    |> range(start: 2023-01-01T00:00:00Z, stop: 2025-01-01T00:00:00Z)
    |> filter(fn: (r) => r._measurement == "larval_development")
    |> filter(fn: (r) => r._field == "pct_complete" and r.model == "pokrocily")
    |> keep(columns: ["_time", "_value", "species"])
    |> yield(name: "vyvoj")


// ---------------------------------------------------------------------
// 6. Kontrola po nahrání: počet bodů a časový rozsah
// ---------------------------------------------------------------------
from(bucket: "mosprema")
    |> range(start: 2023-01-01T00:00:00Z, stop: 2025-01-01T00:00:00Z)
    |> filter(fn: (r) => r._measurement == "sensor_reading")
    |> group()
    |> reduce(
        identity: {pocet: 0, prvni: 2030-01-01T00:00:00Z, posledni: 2000-01-01T00:00:00Z},
        fn: (r, accumulator) => ({
            pocet: accumulator.pocet + 1,
            prvni: if r._time < accumulator.prvni then r._time else accumulator.prvni,
            posledni: if r._time > accumulator.posledni then r._time else accumulator.posledni,
        }),
    )
    |> yield(name: "kontrola")
