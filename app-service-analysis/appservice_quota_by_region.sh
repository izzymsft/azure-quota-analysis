#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# App Service quota + SKU availability by region (NO provisioning attempts)
#
# Usage:
#   ./appservice_quota_by_region.sh --sku B1
#   ./appservice_quota_by_region.sh --sku S1 --linux
#   ./appservice_quota_by_region.sh --sku P1V3 --windows
#
# Outputs:
#   ./appservice_quota_by_region/summary_<SKU>.tsv
#   ./appservice_quota_by_region/detail_<SKU>.tsv
#
# Notes:
# - SKU availability is based on `az appservice list-locations --sku <SKU>`.
# - Quota/usage is best-effort via Microsoft.Web locations usages endpoint.
# ------------------------------------------------------------------------------

API_VERSION="${API_VERSION:-2025-03-01}"
OUT_DIR="${OUT_DIR:-./appservice_quota_by_region}"
mkdir -p "$OUT_DIR"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need_cmd az
need_cmd jq

SKU="${SKU:-}"                 # can be passed via env or --sku
LINUX_WORKERS_ENABLED="0"      # set via --linux
HYPERV_WORKERS_ENABLED="0"     # set via --windows

usage() {
  cat <<EOF
Usage:
  $0 --sku <SKU> [--linux | --windows]

Examples:
  $0 --sku B1 --linux
  $0 --sku S1
  $0 --sku P1V3 --windows

Environment variables (optional):
  API_VERSION   (default: ${API_VERSION})
  OUT_DIR       (default: ${OUT_DIR})
  SKU           (alternative to --sku)

EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)
      SKU="${2:-}"
      shift 2
      ;;
    --linux)
      LINUX_WORKERS_ENABLED="1"
      HYPERV_WORKERS_ENABLED="0"
      shift
      ;;
    --windows|--hyperv)
      HYPERV_WORKERS_ENABLED="1"
      LINUX_WORKERS_ENABLED="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SKU" ]]; then
  echo "Error: --sku <SKU> is required (or set SKU env var)." >&2
  usage
  exit 1
fi

# Normalize SKU for filenames
SKU_SAFE="$(echo "$SKU" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
SUB_ID="$(az account show --query id -o tsv)"
echo "Using subscription: $SUB_ID"
echo "Target SKU: $SKU"
if [[ "$LINUX_WORKERS_ENABLED" == "1" ]]; then echo "Worker type: Linux"; fi
if [[ "$HYPERV_WORKERS_ENABLED" == "1" ]]; then echo "Worker type: Windows/HyperV"; fi
if [[ "$LINUX_WORKERS_ENABLED" == "0" && "$HYPERV_WORKERS_ENABLED" == "0" ]]; then
  echo "Worker type: Not specified (Azure will return general SKU availability)"
fi

# Regions available to the subscription
az account list-locations -o json > "$OUT_DIR/subscription_locations.json"
jq -r '.[].name | ascii_downcase' "$OUT_DIR/subscription_locations.json" | sort -u > "$OUT_DIR/sub_regions.txt"

# Regions where the requested SKU is available for App Service Plans
APP_LOC_ARGS=(--sku "$SKU")
if [[ "$LINUX_WORKERS_ENABLED" == "1" ]]; then APP_LOC_ARGS+=(--linux-workers-enabled); fi
if [[ "$HYPERV_WORKERS_ENABLED" == "1" ]]; then APP_LOC_ARGS+=(--hyperv-workers-enabled); fi

az appservice list-locations "${APP_LOC_ARGS[@]}" -o json > "$OUT_DIR/appservice_${SKU_SAFE}_locations.json"
jq -r '.[].name | ascii_downcase' "$OUT_DIR/appservice_${SKU_SAFE}_locations.json" | sort -u > "$OUT_DIR/sku_regions.txt"

# Candidate regions = subscription ∩ SKU availability
comm -12 "$OUT_DIR/sub_regions.txt" "$OUT_DIR/sku_regions.txt" > "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt"

SUMMARY_TSV="$OUT_DIR/summary_${SKU_SAFE}.tsv"
DETAIL_TSV="$OUT_DIR/detail_${SKU_SAFE}.tsv"

echo -e "region\tsku_available_in_region\tquota_api_status\tquota_item_count" > "$SUMMARY_TSV"
echo -e "region\tquota_metric\tcurrent\tlimit\tremaining\tunit\tnextResetTime" > "$DETAIL_TSV"

echo
echo "Candidate regions (subscription ∩ SKU=${SKU} availability):"
if [[ -s "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt" ]]; then
  sed 's/^/  - /' "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt"
else
  echo "  (none)"
fi
echo

# Minimal URL encode helper (region names usually don't need it, but safe)
urlencode() {
  python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${1}", safe=""))
PY
}

while read -r region; do
  [[ -z "$region" ]] && continue
  echo "Checking quota/usage: $region"

  enc_region="$(urlencode "$region")"
  url="https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Web/locations/${enc_region}/usages?api-version=${API_VERSION}"

  quota_json="$OUT_DIR/usages_${region}_${SKU_SAFE}.json"
  if az rest --method get --url "$url" -o json > "$quota_json" 2>/dev/null; then
    item_count="$(jq -r '.value | length' "$quota_json" 2>/dev/null || echo 0)"
    echo -e "${region}\ttrue\tok\t${item_count}" >> "$SUMMARY_TSV"

    jq -r --arg region "$region" '
      (.value // [])
      | .[]
      | [
          $region,
          (.name.value // .name.localizedValue // "unknown"),
          (.currentValue // 0),
          (.limit // 0),
          ((.limit // 0) - (.currentValue // 0)),
          (.unit // ""),
          (.nextResetTime // "")
        ]
      | @tsv
    ' "$quota_json" >> "$DETAIL_TSV"
  else
    echo -e "${region}\ttrue\tunavailable\t0" >> "$SUMMARY_TSV"
  fi
done < "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt"

echo
echo "Done."
echo "Summary: $SUMMARY_TSV"
echo "Detail:  $DETAIL_TSV"
echo
echo "Tip: show quota rows with a meaningful limit (>0) sorted by remaining:"
awk -F'\t' 'NR>1 && $4 ~ /^[0-9]+$/ && $4>0 {print $0}' "$DETAIL_TSV" \
  | sort -t$'\t' -k5,5nr \
  | head -n 20 \
  | column -t -s $'\t'
