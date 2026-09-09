// Kontrola po nahrání: kolik bodů je v bucketu podle measurement.
//
// Dotaz je schválně v souboru, ne v proměnné. PowerShell 5.1 rozdělí
// víceřádkový řetězec předaný nativnímu programu na jednotlivá slova
// a influx pak hlásí "undefined identifier" u prvního tokenu.
//
//   docker compose exec -T influxdb influx query --org upol --token <token> --file /import/verify.flux
from(bucket: "mosprema")
    |> range(start: 2023-01-01T00:00:00Z, stop: 2025-01-01T00:00:00Z)
    |> group(columns: ["_measurement"])
    |> count()
    |> keep(columns: ["_measurement", "_value"])
    |> yield(name: "pocty")
