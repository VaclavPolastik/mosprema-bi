# =====================================================================
# Rozjede celý stack jedním příkazem:
#
#     .\start-stack.ps1
#
# Postup: ověří Docker, doplní chybějící výstupy ETL, nastartuje
# PostgreSQL + InfluxDB + Grafanu, počká, až databáze naběhne,
# nahraje telemetrii do Influxu a zkontroluje počty řádků.
#
# Skript je idempotentní — spadne-li uprostřed, dá se pustit znovu.
#
# Dvě věci, na kterých tenhle skript původně ztroskotal a stojí za to
# je znát, protože potkají každý PowerShell 5.1 skript kolem Dockeru:
#
#  1. Soubor musí být uložen v UTF-8 *s BOM*. Bez BOM ho Windows
#     PowerShell čte jako ANSI, em dash se rozpadne na tři znaky a ta
#     uvozovka uprostřed ukončí řetězec — skript pak neprojde ani
#     parserem.
#  2. `docker compose` hlásí průběh stahování na stderr. PowerShell 5.1
#     z každého takového řádku udělá NativeCommandError a při
#     $ErrorActionPreference = "Stop" tím celý skript spadne, i když
#     se ve skutečnosti nic nepokazilo. Proto jdou všechna nativní
#     volání přes Invoke-Native, které se řídí návratovým kódem.
# =====================================================================

[CmdletBinding()]
param(
    [switch]$SkipEtl,      # nepřegenerovávat CSV
    [switch]$SkipInflux    # nenahrávat do InfluxDB
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# .env cte docker compose sam, ale skript z nej potrebuje aspon port Grafany,
# aby na konci vypsal spravnou adresu.
$envVars = @{}
if (Test-Path ".env") {
    Get-Content ".env" | Where-Object { $_ -match "^\s*[^#].*=" } | ForEach-Object {
        $k, $v = $_ -split "=", 2
        $envVars[$k.Trim()] = $v.Trim()
    }
}
$grafanaPort = if ($envVars["GRAFANA_PORT"]) { $envVars["GRAFANA_PORT"] } else { "3000" }

function Say($msg)  { Write-Host "  $msg" }
function Step($msg) { Write-Host "`n[$msg]" -ForegroundColor Cyan }
function Die($msg)  { Write-Host "`nCHYBA: $msg" -ForegroundColor Red; exit 1 }

function Invoke-Native {
    <#
      Spustí externí program a rozhodne o úspěchu podle návratového kódu,
      ne podle toho, jestli něco napsal na stderr.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Exe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $What = "příkaz",
        [switch] $Quiet,
        [switch] $AllowFail
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = ""
    try {
        if ($Quiet) {
            $out = (& $Exe @Arguments 2>&1 | Out-String)
        } else {
            & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0 -and -not $AllowFail) { Die "$What skončil s chybou $code" }
    return @{ Code = $code; Output = $out }
}

# ---------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------
Step "Docker"

$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) { $docker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe" }
if (-not (Test-Path $docker)) {
    Die "Docker není nainstalovaný. Nainstaluj ho: winget install --id Docker.DockerDesktop --exact"
}
Say "klient: $docker"

$server = (Invoke-Native $docker @("version", "--format", "{{.Server.Version}}") -What "docker version" -Quiet -AllowFail).Output.Trim()
if ([string]::IsNullOrWhiteSpace($server)) {
    Write-Host ""
    Write-Host "Docker daemon neběží." -ForegroundColor Yellow
    Say "1. Spusť Docker Desktop a počkej, až ikona přestane blikat."
    Say "2. Hlásí-li 'WSL needs updating', spusť ve správcovském PowerShellu: wsl --update"
    Say "3. Hlásí-li 'unable to start' hned po instalaci, restartuj Windows."
    Say "4. Pak spusť tenhle skript znovu."
    exit 1
}
Say "daemon: $server"

# ---------------------------------------------------------------------
# 2. Výstupy ETL
# ---------------------------------------------------------------------
Step "Data"

$needEtl = -not (Test-Path "out\fact_reading.csv") -or -not (Test-Path "influx\mosprema.lp")
if ($needEtl -and -not $SkipEtl) {
    Say "chybí výstupy ETL, generuji…"
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { Die "Python není v PATH. Spusť ručně: python etl\build_warehouse.py" }
    Invoke-Native $py @("etl\build_warehouse.py") -What "ETL" | Out-Null
    Invoke-Native $py @("etl\validate.py") -What "validace" | Out-Null
} else {
    Say "výstupy ETL jsou na místě"
}

# ---------------------------------------------------------------------
# 3. Kontejnery
# ---------------------------------------------------------------------
Step "Kontejnery"
Say "spouštím kontejnery (napoprvé se stahují image, to chvíli potrvá)"

Invoke-Native $docker @("compose", "up", "-d") -What "docker compose up" | Out-Null

Say "čekám, až PostgreSQL projde health checkem…"
$ok = $false
foreach ($i in 1..45) {
    $state = (Invoke-Native $docker @("inspect", "-f", "{{.State.Health.Status}}", "mosprema-postgres") `
                -What "docker inspect" -Quiet -AllowFail).Output.Trim()
    if ($state -eq "healthy") { $ok = $true; break }
    Start-Sleep -Seconds 4
}
if (-not $ok) { Die "PostgreSQL nenaběhl. Podívej se na log: docker compose logs postgres" }
Say "PostgreSQL běží"

# ---------------------------------------------------------------------
# 4. Kontrola nahraných dat
# ---------------------------------------------------------------------
Step "Kontrola PostgreSQL"

# Data nahrává init skript uvnitř kontejneru při prvním startu prázdného svazku.
$sql = "SELECT count(*) FROM mosprema.fact_reading;"
$res = (Invoke-Native $docker @("compose", "exec", "-T", "postgres", "psql", "-U", "mosprema", "-d", "mosprema", "-tAc", $sql) `
          -What "dotaz do PostgreSQL" -Quiet -AllowFail)
$rows = ($res.Output -replace "[^\d]", "")
if ($res.Code -ne 0 -or -not $rows) {
    Write-Host "  Dotaz do PostgreSQL neprošel:" -ForegroundColor Yellow
    Say $res.Output.Trim()
} else {
    Say "fact_reading: $rows řádků"
    if ($rows -ne "139791") {
        Write-Host "  POZOR: počet neodpovídá protokolu ETL (139791)." -ForegroundColor Yellow
        Say "Init skript plní databázi jen při prvním startu prázdného svazku."
        Say "Vynulovat a nahrát znovu: docker compose down -v ; .\start-stack.ps1"
    }
}

# ---------------------------------------------------------------------
# 5. InfluxDB
# ---------------------------------------------------------------------
if (-not $SkipInflux) {
    Step "InfluxDB"
    & "$PSScriptRoot\influx\load.ps1"
    if ($LASTEXITCODE -ne 0) { Write-Host "  Nahrání do InfluxDB selhalo." -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------
# 6. Grafana
#
# Kontejner umi bezet i bez publikovaneho portu: kdyz po restartu Dockeru
# drzi cilovy port nekdo jiny (treba nativni instalace Grafany jako sluzba
# Windows), nastartuje, ale zvenku na nej nikdo nedosahne. "docker compose ps"
# takovy kontejner hlasi jako v poradku, takze se to pozna jen zkusenim.
# ---------------------------------------------------------------------
Step "Grafana"

$grafanaOk = $false
foreach ($i in 1..15) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$grafanaPort/api/health" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) { $grafanaOk = $true; break }
    } catch { Start-Sleep -Seconds 3 }
}
if ($grafanaOk) {
    Say "odpovídá na portu $grafanaPort"
} else {
    Write-Host "  Grafana na portu $grafanaPort neodpovídá." -ForegroundColor Yellow
    Say "Zkontroluj, jestli má kontejner publikovaný port:"
    Say "  docker port mosprema-grafana"
    Say "Nevypíše-li nic, drží port někdo jiný. Zjistíš to takhle:"
    Say "  Get-NetTCPConnection -LocalPort $grafanaPort -State Listen"
    Say "Změň GRAFANA_PORT v .env a spusť skript znovu."
}

# ---------------------------------------------------------------------
# 7. Hotovo
# ---------------------------------------------------------------------
Step "Hotovo"
Say "Grafana    http://localhost:$grafanaPort      admin / admin"
Say "InfluxDB   http://localhost:8086      mosprema / mosprema123"
Say "PostgreSQL localhost:5432             mosprema / mosprema"
Write-Host ""
Say "Dashboardy najdeš v Grafaně ve složce mosprema_206."
