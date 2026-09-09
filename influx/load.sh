#!/usr/bin/env bash
# =====================================================================
# Nahrání telemetrie do InfluxDB (varianta pro bash / WSL / Linux).
#
#     ./influx/load.sh
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

LP="influx/mosprema.lp"
[ -f "$LP" ] || { echo "Chybí $LP — nejdřív spusť: python etl/build_warehouse.py" >&2; exit 1; }

echo "Nahrávám $(wc -l < "$LP") řádků line protocolu do bucketu ${INFLUX_BUCKET}…"

docker compose exec -T influxdb influx write \
    --bucket "$INFLUX_BUCKET" \
    --org "$INFLUX_ORG" \
    --token "$INFLUX_TOKEN" \
    --precision ns \
    --file /import/mosprema.lp

echo
echo "Kontrola počtu záznamů:"
# Stejný dotaz jako v load.ps1 — ze souboru, aby obě varianty ověřovaly totéž.
docker compose exec -T influxdb influx query \
    --org "$INFLUX_ORG" --token "$INFLUX_TOKEN" \
    --file /import/verify.flux

echo
echo "Hotovo. Grafana: http://localhost:3000"
