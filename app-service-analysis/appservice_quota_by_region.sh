#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# App Service SKU availability + quota remaining by region (NO provisioning attempts)
#
# Usage:
#   ./appservice_quota_by_region.sh --sku B1
#   ./appservice_quota_by_region.sh --sku S1 --linux
#   ./appservice_quota_by_region.sh --sku P1V3 --windows
#
# Optional env vars:
#   OUT_DIR=./out
#   API_VERSION=2025-03-01
#   PLAN_QUOTA_REGEX='Server Farm|serverfarms|App Service Plan|AppServicePlan'
# ------------------------------------------------------------------------------

API_VERSION="${API_VERSION:-2025-03-01}"
OUT_DIR="${OUT_DIR:-./appservice_quota_by_region}"
PLAN_QUOTA_REGEX="${PLAN_QUOTA_REGEX:-Server Farm|serverfarms|App Service Plan|AppServicePlan}"

mkdir -p "$OUT_DIR"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need_cmd az
need_cmd jq

SKU="${SKU:-}"                 # can be set via env or --sku
LINUX_WORKERS_ENABLED="0"      # set via --linux
HYPERV_WORKERS_ENABLED="0"     # set via --windows/--hyperv

usage() {
  cat <<EOF
Usage:
  $0 --sku <SKU> [--linux | --windows]

Examples:
  $0 --sku B1 --linux
  $0 --sku S1
  $0 --sku P1V3 --windows

Optional env vars:
  OUT_DIR            (default: ${OUT_DIR})
  API_VERSION        (default: ${API_VERSION})
  PLAN_QUOTA_REGEX   (default: ${PLAN_QUOTA_REGEX})

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

SKU_SAFE="$(echo "$SKU" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
SUB_ID="$(az account show --query id -o tsv)"
echo "Using subscription: $SUB_ID"
echo "Target SKU: $SKU"
echo "PLAN_QUOTA_REGEX: $PLAN_QUOTA_REGEX"
if [[ "$LINUX_WORKERS_ENABLED" == "1" ]]; then echo "Worker type: Linux"; fi
if [[ "$HYPERV_WORKERS_ENABLED" == "1" ]]; then echo "Worker type: Windows/HyperV"; fi
if [[ "$LINUX_WORKERS_ENABLED" == "0" && "$HYPERV_WORKERS_ENABLED" == "0" ]]; then
  echo "Worker type: Not specified (general SKU availability)"
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

# Summary shows "how much quota is available" in each region:
# - plan_remaining: remaining quota for the best-matching plan/serverfarm metric (if present)
# - min_remaining/min_metric: the tightest quota counter in that region (remaining smallest)
echo -e "region\tsku_available\tquota_api_status\tlimited_metrics\tplan_remaining\tmin_remaining\tmin_metric" > "$SUMMARY_TSV"
echo -e "region\tquota_metric\tcurrent\tlimit\tremaining\tunit\tnextResetTime" > "$DETAIL_TSV"

echo
echo "Candidate regions (subscription ∩ SKU=${SKU} availability):"
if [[ -s "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt" ]]; then
  sed 's/^/  - /' "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt"
else
  echo "  (none)"
fi
echo

# Minimal URL encode helper (region names typically do not need it, but safe)
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
    # Build a normalized list of metrics with non-zero limits (these represent actual quota ceilings)
    # Then compute:
    #   limited_metrics count
    #   plan_remaining: min remaining among "plan-ish" metrics matched by PLAN_QUOTA_REGEX
    #   min_remaining + min_metric: most constraining quota counter overall
    summary_line="$(
      jq -r --arg region "$region" --arg planre "$PLAN_QUOTA_REGEX" '
        def metric_name: (.name.value // .name.localizedValue // "unknown");
        def current: (.currentValue // 0);
        def limit:   (.limit // 0);
        def remaining: (limit - current);

        [ (.value // [])
          | .[]
          | select(limit > 0)
          | { name: metric_name, remaining: remaining }
        ] as $m
        | ($m | length) as $cnt
        | (
            $m
            | map(select(.name | test($planre; "i")))
            | sort_by(.remaining)
            | (if length > 0 then .[0].remaining else "" end)
          ) as $plan_remaining
        | (
            $m
            | sort_by(.remaining)
            | (if length > 0 then .[0] else {remaining:"", name:""} end)
          ) as $min
        | [
            $region,
            "true",
            "ok",
            ($cnt|tostring),
            ($plan_remaining|tostring),
            ($min.remaining|tostring),
            ($min.name|tostring)
          ]
        | @tsv
      ' "$quota_json"
    )"
    echo -e "$summary_line" >> "$SUMMARY_TSV"

    # Detail rows: every metric with remaining computed
    jq -r --arg region "$region" '
      def metric_name: (.name.value // .name.localizedValue // "unknown");
      def current: (.currentValue // 0);
      def limit:   (.limit // 0);
      def remaining: (limit - current);

      (.value // [])
      | .[]
      | [
          $region,
          metric_name,
          current,
          limit,
          remaining,
          (.unit // ""),
          (.nextResetTime // "")
        ]
      | @tsv
    ' "$quota_json" >> "$DETAIL_TSV"

  else
    echo -e "${region}\ttrue\tunavailable\t0\t\t\t" >> "$SUMMARY_TSV"
  fi
done < "$OUT_DIR/candidate_regions_${SKU_SAFE}.txt"

echo
echo "Done."
echo "Summary: $SUMMARY_TSV"
echo "Detail:  $DETAIL_TSV"
echo

echo "Summary table (quota remaining by region):"
column -t -s $'\t' "$SUMMARY_TSV" | sed 's/^/  /'

echo
echo "Tip: show only regions with a numeric plan_remaining (best proxy metric):"
awk -F'\t' 'NR==1 || $5 ~ /^[0-9-]+$/' "$SUMMARY_TSV" | column -t -s $'\t'