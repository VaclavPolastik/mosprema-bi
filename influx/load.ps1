# =====================================================================
# Nahrání telemetrie do InfluxDB.
#
#     .\influx\load.ps1
#
# Soubor mosprema.lp je do kontejneru připojený jako /import/mosprema.lp,
# takže se nemusí posílat po síti — influx ho čte z disku.
# =====================================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Načtení .env, ať jsou údaje na jednom místě
$env_vars = @{}
Get-Content ".env" | Where-Object { $_ -match "^\s*[^#].*=" } | ForEach-Object {
    $k, $v = $_ -split "=", 2
    $env_vars[$k.Trim()] = $v.Trim()
}

$lp = Join-Path $root "influx\mosprema.lp"
if (-not (Test-Path $lp)) {
    throw "Chybí $lp — nejdřív spusť: python etl\build_warehouse.py"
}
$lines = (Get-Content $lp | Measure-Object -Line).Lines
Write-Host "Nahravam $lines radku line protocolu do bucketu $($env_vars['INFLUX_BUCKET'])..."

# influx write hlasi prubeh na stderr a PowerShell 5.1 z kazdeho takoveho
# radku udela NativeCommandError; pri "Stop" by tim skript spadl, i kdyz
# zapis probehl. O uspechu proto rozhoduje az navratovy kod nize.
$ErrorActionPreference = "Continue"

# --precision ns odpovídá tomu, co zapisuje ETL (nanosekundy od epochy)
docker compose exec -T influxdb influx write `
    --bucket   $env_vars['INFLUX_BUCKET'] `
    --org      $env_vars['INFLUX_ORG'] `
    --token    $env_vars['INFLUX_TOKEN'] `
    --precision ns `
    --file     /import/mosprema.lp

if ($LASTEXITCODE -ne 0) { throw "influx write skoncil s chybou $LASTEXITCODE" }

Write-Host "`nKontrola poctu zaznamu:"

# Dotaz jde ze souboru, ne z promenne. PowerShell 5.1 rozdeli viceradkovy
# retezec predany nativnimu programu na jednotliva slova a influx pak hlasi
# "undefined identifier" u prvniho tokenu.
docker compose exec -T influxdb influx query `
    --org   $env_vars['INFLUX_ORG'] `
    --token $env_vars['INFLUX_TOKEN'] `
    --file  /import/verify.flux

if ($LASTEXITCODE -ne 0) { throw "kontrolni dotaz skoncil s chybou $LASTEXITCODE" }

$port = if ($env_vars['GRAFANA_PORT']) { $env_vars['GRAFANA_PORT'] } else { "3000" }
Write-Host "`nHotovo. Grafana: http://localhost:$port"
